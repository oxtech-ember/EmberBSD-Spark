-- Responses and token accounting follow the Asenta gateway protocol.
-- The client owns endpoints and credentials. No paid request is replayed after
-- a transport failure; only a known model refusal may select the spare alias.
local json = require("json")
local Model = {}
Model.__index = Model

local function object(value)
    return type(value) == "table" and value ~= json.null and value or {}
end
local function number(value) return tonumber(value) or 0 end
local function nonempty(value) return type(value) == "string" and value ~= "" end
local function copy(value)
    local result = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end
local function message(err)
    return type(err) == "table" and (err.message or err.reason or "model request failed") or tostring(err)
end

-- Both catalogue shapes become dollars per million tokens. OpenRouter bands
-- give lower bounds; pricebook uses inclusive upper bounds and a final rate.
local function seatOf(raw)
    local meta, remote = object(raw.metadata), object(raw.pricing)
    local p = object(meta.pricing)
    local price = {input=number(p.input_per_mtok), output=number(p.output_per_mtok),
        cached=number(p.cached_input_per_mtok), currency=p.currency, tiers={}}
    for _, tier in ipairs(object(p.tiers)) do
        price.tiers[#price.tiers + 1] = {upto=number(tier.up_to_tokens),
            input=number(tier.input_per_mtok), output=number(tier.output_per_mtok)}
    end
    local top = object(raw.top_provider)
    local window, maximum = number(meta.context_window), number(meta.max_output_tokens)
    if window <= 0 then
        window = number(top.context_length)
        if window == 0 then window = number(raw.context_length) end
        if maximum == 0 then maximum = number(top.max_completion_tokens) end
        if remote.prompt or remote.completion or remote.input_cache_read or remote.overrides then
            price.input, price.output = number(remote.prompt) * 1e6, number(remote.completion) * 1e6
            price.cached, price.currency = number(remote.input_cache_read) * 1e6, "USD"
            local bands = {}
            for _, band in ipairs(object(remote.overrides)) do bands[#bands + 1] = band end
            table.sort(bands, function(a, b) return number(a.min_prompt_tokens) < number(b.min_prompt_tokens) end)
            for _, band in ipairs(bands) do
                if number(band.min_prompt_tokens) > 0 then
                    price.tiers[#price.tiers + 1] = {upto=number(band.min_prompt_tokens)-1,
                        input=price.input, output=price.output}
                    price.input, price.output = number(band.prompt)*1e6, number(band.completion)*1e6
                    if number(band.input_cache_read) > 0 then price.cached = number(band.input_cache_read)*1e6 end
                end
            end
        end
    end
    return {alias=raw.id, model=nonempty(meta.display_name) and meta.display_name or (nonempty(raw.name) and raw.name or raw.id),
        price=price, contextWindow=window, maxOutput=maximum,
        api=nonempty(meta.api) and meta.api or (nonempty(raw.api) and raw.api or "responses")}
end

-- Cost uses the tier selected by the WHOLE input; cached tokens are part of it.
-- chargedUnits=0 is the server's spelling of "charge units without discount".
function Model.accounting(response, seat)
    local u, p = object(response.usage), object(seat.price)
    local valid = true
    local function count(value)
        if value == nil or value == json.null then return 0 end
        if type(value) ~= "number" or value < 0 or value >= math.huge or value % 1 ~= 0 then
            valid = false
            return 0
        end
        return value
    end
    local input, output, total = count(u.input_tokens), count(u.output_tokens), count(u.total_tokens)
    local reportedCache = count(object(u.input_tokens_details).cached_tokens)
    local cached = math.max(0, math.min(input, reportedCache))
    local inRate, outRate = number(p.input), number(p.output)
    local known = inRate > 0 or outRate > 0
    for _, tier in ipairs(object(p.tiers)) do
        if input <= tier.upto then inRate, outRate = tier.input, tier.output; break end
    end
    local cacheRate = number(p.cached) > 0 and p.cached or inRate
    local charge, cost = total, 0
    if known then
        cost = math.floor((input-cached)*inRate + cached*cacheRate + output*outRate)
        if total > 0 and cached <= total and inRate > 0 and cacheRate > 0 and cacheRate < inRate then
            charge = total - cached + math.ceil(cached * (cacheRate / inRate))
        end
    end
    local notes = {}
    if not known then notes[#notes + 1] = "Catalogue pricing is unknown; costMicro is not a free price." end
    local silent = total <= 0 and input <= 0 and output <= 0
    -- A partial nonstandard count cannot debit the token ledger reliably.
    if total <= 0 and not silent then
        notes[#notes + 1] = "The provider omitted total_tokens; the token charge is unknown."
    end
    if total > 0 and input <= 0 and output <= 0 then
        notes[#notes + 1] = "The provider omitted its token split; the money cost is unknown."
    end
    if not valid then notes[#notes + 1] = "The provider returned an invalid token count; spending is incomplete." end
    return {units=total, cachedUnits=reportedCache, chargedUnits=charge > 0 and charge < total and charge or 0,
        costMicro=cost, spendUnknown=not valid or silent or total <= 0}, known, notes
end

local function reject(reason, text, reply)
    local err = {reason=reason, message=text}
    if reply then
        err.usage, err.modelAlias, err.model = reply.usage, reply.modelAlias, reply.model
        err.priceKnown, err.accountingNotes = reply.priceKnown, reply.accountingNotes
    end
    error(err, 0)
end

-- A paid but unusable response raises a structured error WITH usage. The engine
-- records that usage before deciding how to continue; no calls escape a cut.
function Model.parse(response, seat)
    if nonempty(response.reason) or (response.error ~= nil and response.error ~= json.null) then
        local detail = response.error
        local err = {reason=nonempty(response.reason) and response.reason or nil, gateway=not nonempty(response.reason),
            message=type(detail) == "table" and detail.message or detail or "Model refused"}
        if type(response.usage) == "table" and response.usage ~= json.null then
            err.usage, err.priceKnown, err.accountingNotes = Model.accounting(response, seat)
            err.modelAlias, err.model = seat.alias, seat.model
        end
        error(err, 0)
    end
    local usage, known, notes = Model.accounting(response, seat)
    local reply = {answer="", calls=json.array(), items=response.output or json.array(), usage=usage,
        modelAlias=seat.alias, model=seat.model or seat.alias, priceKnown=known, accountingNotes=notes}
    reply.inputTokens = object(response.usage).input_tokens
    reply.outputTokens = object(response.usage).output_tokens
    if nonempty(response.status) and response.status ~= "completed" then
        reject("model_incomplete", "Model response is not complete: " .. tostring(response.status), reply)
    end
    local text, seen = {}, {}
    for _, item in ipairs(object(response.output)) do
        if item.status == "incomplete" then reject("model_incomplete", "Model output item is incomplete", reply) end
        if item.type == "message" then
            for _, part in ipairs(object(item.content)) do
                if part.type == "refusal" then reject("model_refused", part.refusal or part.text or "Model refused", reply) end
                if nonempty(part.text) then text[#text + 1] = part.text end
            end
        elseif item.type == "function_call" then
            if not nonempty(item.call_id) or not nonempty(item.name) or seen[item.call_id] then
                reject("model_bad_call", "Model returned a missing or duplicate call identifier/name", reply)
            end
            seen[item.call_id] = true
            local ok, args = pcall(json.decode, item.arguments or "")
            local call = {id=item.call_id, name=item.name, arguments=item.arguments, args=ok and args or {}}
            if not ok or type(args) ~= "table" or args == json.null then
                call.args, call.error = {}, "Invalid tool arguments: " .. (ok and "expected an object" or tostring(args))
            end
            reply.calls[#reply.calls + 1] = call
        end
    end
    reply.answer = table.concat(text, "\n")
    if reply.answer == "" and #reply.calls == 0 then
        reject("model_empty", "Model returned neither text nor a supported function call", reply)
    end
    return reply
end

function Model.new(config, client)
    return setmetatable({config=config.model or {}, client=client, seats={}, chosen={}}, Model)
end

function Model:open(alias)
    alias = alias or self.config.alias
    assert(nonempty(alias), "model.alias is required")
    if not self.catalogueRead then
        self.catalogueRead = true
        local ok, catalogue = pcall(self.client.request, self.client, "GET", "/v1/models", nil, true,
            {maxBytes=self.config.catalogueMaxBytes or 4*1024*1024})
        if ok then
            for _, raw in ipairs(object(catalogue.data)) do
                if nonempty(raw.id) then self.seats[raw.id] = seatOf(raw) end
            end
        else
            self.catalogueError = message(catalogue)
        end
    end
    local selected = self.chosen[alias] or alias
    local seat = self.seats[selected]
    local spare = self.config.fallback
    if not self.catalogueError and (not seat or seat.contextWindow <= 0) and nonempty(spare) and selected ~= spare then
        selected, seat = spare, self.seats[spare]
        self.chosen[alias] = spare
    end
    seat = copy(seat or {alias=selected, model=selected, contextWindow=0, maxOutput=0, price={}})
    local primary = self.seats[alias]
    if selected ~= alias and seat.contextWindow <= 0 and primary and primary.contextWindow > 0 then
        seat.contextWindow, seat.maxOutput, seat.borrowed = primary.contextWindow, primary.maxOutput, true
    end
    seat.catalogueError = self.catalogueError
    self.seat = seat
    return seat
end

local function reserve(seat, asked)
    asked = number(asked)
    if seat.maxOutput <= 0 then return asked > 0 and asked or nil end
    if asked > 0 and asked < seat.maxOutput then return asked end
    return math.min(seat.maxOutput, 32000)
end

local function gatewayError(err)
    return type(err) == "table" and not nonempty(err.reason) and number(err.status) > 0
end
local function modelRefused(err)
    if not gatewayError(err) then return false end
    local status, said = err.status, message(err):lower()
    if status == 401 or status == 403 or status == 404 then return true end
    if status == 429 then return said:find("day token limit", 1, true) ~= nil end
    for _, phrase in ipairs({"safety guard unavailable", "rate limit exceeded for /",
        "circuit breaker is open", "request blocked by safety policy"}) do
        if said:find(phrase, 1, true) then return true end
    end
    return false
end

-- pricebook.RoomAfter: one smaller ask after an explicit affordable token count.
local function affordable(text, asked)
    text = text:lower():gsub("\194\160", " "):gsub("\226\128\175", " ")
    local digits, rest = text:match("%f[%a]afford%s+(%d+)(.*)")
    if not digits then return nil end
    while rest:match("^[, ]%d%d%d") do
        digits, rest = digits .. rest:sub(2, 4), rest:sub(5)
    end
    local room = math.floor(tonumber(digits) / 10) * 9
    if room >= 1024 and (not asked or room < asked) then return room end
end

function Model:request(input, definitions, task)
    local primary = task and nonempty(task.seat) and task.seat or self.config.alias
    local seat = self:open(primary)
    -- Project one declaration at a time, retaining only the source sequence.
    local tools = setmetatable({}, {__jsontype="array",__len=function() return #(definitions or {}) end,
        __index=function(_,index)
            local spec=definitions[index]
            if spec then return {type="function",name=spec.name,description=spec.description,parameters=spec.parameters} end
        end,
        __pairs=function(value) return ipairs(value) end})
    local function turn(at)
        if at.api and at.api ~= "responses" then
            reject("model_api_unsupported", "This adapter supports Responses, not " .. at.api)
        end
        local request = {model=at.alias, input=input, tools=#tools > 0 and tools or nil,
            store=false, max_output_tokens=reserve(at, self.config.maxAnswer)}
        local ok, response, status = pcall(self.client.request, self.client, "POST", "/v1/responses", request, true)
        if not ok and gatewayError(response) then
            local room = affordable(message(response), request.max_output_tokens)
            if room then
                request.max_output_tokens = room
                ok, response, status = pcall(self.client.request, self.client, "POST", "/v1/responses", request, true)
            end
        end
        if not ok then return false, response end
        local parsed, reply = pcall(Model.parse, response, at)
        if not parsed and type(reply) == "table" and reply.gateway then reply.status = status or 200 end
        return parsed, reply
    end
    local ok, reply = turn(seat)
    local spare = self.config.fallback
    if not ok and modelRefused(reply) and nonempty(spare) and seat.alias ~= spare then
        self.chosen[primary] = spare
        seat = self:open(primary)
        ok, reply = turn(seat)
    end
    if not ok then
        local err = type(reply) == "table" and copy(reply) or {message=tostring(reply)}
        err.modelAlias, err.model = seat.alias, seat.model
        error(err, 0)
    end
    return reply
end

return Model
