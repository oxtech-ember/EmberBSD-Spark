-- The address/provenance portion of loop/{address,chain,facts}. The workflow
-- still owns accepted mutators, the offered shelf, source bounds and approvals.
-- Only actual tool results reach heard(); a chain refusal must never do so.
local json = require("json")
local Provenance = {}
Provenance.__index = Provenance
local scheme = "[Hh][Tt][Tt][Pp][Ss]?://"
local address = scheme .. "[^%s\"'<>\\`]+"
local linked = scheme .. "[^%s\"<>\\`]+"
local function object(value) return type(value) == "table" and value ~= json.null end
local function trim(value) return (value or ""):match("^%s*(.-)%s*$") end
local function text(value) return type(value) == "string" and value or "" end
local function unglued(value) return value:gsub("(" .. linked .. ")([\"<>\\`])", "%1\n%2") end
local function lower_schemes(value)
    return value:gsub(address,function(url) return url:gsub("^([^:]+)",string.lower,1) end)
end
local function unclose(value, apostrophe)
    while value ~= "" do
        local last = value:sub(-1)
        if (".,;:)]}"):find(last,1,true) or apostrophe and last == "'" then value=value:sub(1,-2)
        elseif value:sub(-2) == "\194\187" then value=value:sub(1,-3)
        else break end
    end
    return value
end
local function addresses_in(value)
    local found = {}
    for url in text(value):gmatch(address) do found[#found+1] = unclose(url) end
    return table.concat(found,"\n") .. (#found > 0 and "\n" or "")
end
local function each_string(value, see)
    if type(value) == "string" then see(value)
    elseif object(value) then
        for key, child in pairs(value) do
            if type(key) == "string" then see(key) end
            each_string(child,see)
        end
    end
end

-- A token reader, rather than decoding the entire answer: a truncated JSON
-- answer still gives the complete strings before its cut, like json.Decoder.
-- String-valued JSON is decoded three times, the existing jsonDepth contract.
local function quoted_end(value, at)
    local i = at + 1
    while i <= #value do
        local char = value:sub(i,i)
        if char == '"' then return i end
        i = i + (char == "\\" and 2 or 1)
    end
end
local json_strings
json_strings = function(value, depth, see)
    value = trim(value)
    if depth == 0 or value == "" or not ('{["'):find(value:sub(1,1),1,true) then return end
    local at = 1
    local function space() local _,last=value:find("^%s*",at); at=(last or at-1)+1 end
    local function string_token()
        local last = quoted_end(value,at)
        if not last then error(false) end
        local decoded = json.decode(value:sub(at,last))
        at = last + 1
        see(decoded)
        json_strings(decoded,depth-1,see)
        return decoded
    end
    local parse
    parse = function()
        space()
        local char = value:sub(at,at)
        if char == '"' then string_token()
        elseif char == "{" or char == "[" then
            local closing = char == "{" and "}" or "]"
            at = at + 1; space()
            if value:sub(at,at) == closing then at=at+1; return end
            while true do
                if char == "{" then
                    if value:sub(at,at) ~= '"' then error(false) end
                    string_token(); space()
                    if value:sub(at,at) ~= ":" then error(false) end
                    at = at + 1
                end
                parse(); space()
                local ending = value:sub(at,at)
                at = at + 1
                if ending == closing then return end
                if ending ~= "," then error(false) end
                space()
            end
        else
            local token = value:match("^[^%s,%]%}]+",at)
            if not token or token == "" then error(false) end
            local decoded = json.decode(token)
            if type(decoded) ~= "number" and type(decoded) ~= "boolean" and decoded ~= json.null then error(false) end
            at = at + #token
        end
    end
    -- Parsing failure terminates the scan after the complete tokens seen so
    -- far. The text itself remains data; malformed JSON grants no new strings.
    pcall(function() while at <= #value do parse(); space() end end)
end
local function json_addresses(value)
    local found = {}
    json_strings(text(value),3,function(s) found[#found+1]=addresses_in(s) end)
    return table.concat(found)
end
local function data_given(value) return text(value) .. "\n" .. json_addresses(value) end
local function has_space(value)
    if value:find("%s") then return true end
    for _, code in utf8.codes(value) do
        if code == 0x85 or code == 0xA0 or code == 0x1680 or code >= 0x2000 and code <= 0x200A or
            code == 0x2028 or code == 0x2029 or code == 0x202F or code == 0x205F or code == 0x3000 then return true end
    end
    return false
end
local function decoded_args(call)
    if call.args ~= nil then return call.args end
    local ok, value = pcall(json.decode,call.arguments or "")
    if ok then return value end
end
local function addresses_of(call)
    local args, found = decoded_args(call), {}
    if args == nil then
        for url in (call.arguments or ""):gmatch(address) do found[#found+1]=url end
        return found
    end
    local function look(value)
        local whole = trim(value)
        if whole:match("^" .. scheme) and not has_space(whole) then found[#found+1]=whole; return end
        for url in value:gmatch(linked) do found[#found+1]=unclose(url,true) end
    end
    each_string(args,function(value) look(value); json_strings(value,3,look) end)
    return found
end

-- Replace only the injected fields in raw JSON. Other numbers keep their
-- original spelling (including integers beyond double precision) in the trace.
local function mark_arguments(raw, marks)
    local ok, decoded = pcall(json.decode,raw or "")
    if not ok or not object(decoded) or not trim(raw):match("^{") then return end
    local pieces, at = {}, raw:find("{",1,true) + 1
    while true do
        local _,last = raw:find("^%s*",at); at=(last or at-1)+1
        if raw:sub(at,at) == "}" then break end
        local first, keyEnd = at, assert(quoted_end(raw,at))
        local key = json.decode(raw:sub(at,keyEnd))
        at = keyEnd + 1
        local colon = assert(raw:find(":",at,true)); at=colon+1
        local nesting = 0
        while at <= #raw do
            local char = raw:sub(at,at)
            if char == '"' then at=assert(quoted_end(raw,at))+1
            elseif char == "[" or char == "{" then nesting=nesting+1; at=at+1
            elseif char == "]" or char == "}" then
                if nesting == 0 then break end
                nesting=nesting-1; at=at+1
            elseif char == "," and nesting == 0 then break
            else at=at+1 end
        end
        if marks[key] == nil then pieces[#pieces+1]=raw:sub(first,at-1) end
        if raw:sub(at,at) == "}" then break end
        at = at + 1
    end
    for _, key in ipairs({"origin","author"}) do
        if marks[key] ~= nil then pieces[#pieces+1]=json.encode(key) .. ":" .. json.encode(marks[key]) end
    end
    return "{" .. table.concat(pieces,",") .. "}"
end
local function composes(tool, args)
    if not tool then return false end
    if tool.delegates then return true end
    if type(tool.composes) == "function" then return tool.composes(args) end
    return tool.composes == true
end
function Provenance:_tool(name)
    local registry = self.options.registry
    return registry and (registry.byNative[name] or registry:find(name))
end
function Provenance:_hand(value)
    -- Only address membership is queried later. Retaining the surrounding
    -- role, conversation and tool text duplicates the model's disk transcript.
    if type(value) ~= "string" then return end
    self.seen = self.seen or {}
    for url in addresses_in(unglued(value)):gmatch("[^\n]+") do
        if not self.seen[url] then
            self.seen[url] = true
            self.state.given = self.state.given .. url .. "\n"
        end
    end
end
function Provenance:_recorded(tool, call, answer)
    if tool.echoes or composes(tool,decoded_args(call)) then return "" end
    if tool.kept then return addresses_in(answer) .. json_addresses(answer) end
    return data_given(answer)
end
function Provenance.new(options, saved)
    options = options or {}
    if saved == json.null then saved=nil end
    local self = setmetatable({options=options, state=saved or {given="",external=false}},Provenance)
    if saved then
        local given, saw = saved.given, saved.sawGiven
        self.state.given = ""
        self:_hand(given)
        self.state.sawGiven = saw and addresses_in(unglued(saw)) or nil
        return self
    end
    local task, history, actor = options.task or {}, options.history or {}, options.actorId
    self.state.external = options.external == true or options.foreign == true
    for _, key in ipairs({"role","facts","notebook","skills"}) do self:_hand(addresses_in(options[key])) end
    self:_hand(options.colleagues); self:_hand(task.title); self:_hand(task.subtitle)
    for _, input in pairs(options.attachments or {}) do
        if input.contents then self.state.external=true end
        if not input.composed then self:_hand(input.mention); self:_hand(input.note) end
    end
    for _, event in ipairs(history) do
        if event.level ~= "trace" then
            if event.outside then self.state.external=true end
            if event.actorId ~= actor and (not event.actorIsAgent or event.outside) then
                self:_hand(event.title); self:_hand(event.body)
            end
        end
    end
    -- Reconstruct the same last own attempt as loop/recall.go, never a fold,
    -- another executor's trace, nested model steps, or our own refusal text.
    local first, traced = 0, false
    local function ours(event) return event.actorId == actor and not text(event.stepId):find("/",1,true) end
    for index = #history,1,-1 do
        local event = history[index]
        if event.level == "trace" then traced=traced or ours(event)
        elseif event.actorId ~= actor and traced then first=index; break end
    end
    if traced then
        for index = first+1,#history do
            local event = history[index]
            local tool = self:_tool(event.title)
            if tool and ours(event) and event.kind == "message" and event.level == "trace" and event.phase ~= "start" and
                event.errorCode ~= "mutator_refused" and event.errorCode ~= "provenance_refused" then
                self.state.external=true
                self:_hand(self:_recorded(tool,{arguments=event.quoted},event.body))
            end
        end
    end
    for _, recalled in ipairs(options.recalled or {}) do
        local tool = self:_tool(recalled.name)
        if tool then self.state.external=true; self:_hand(self:_recorded(tool,recalled,recalled.answer)) end
    end
    return self
end
function Provenance:context(reply)
    reply = reply or {}
    return {origin=self.state.external and "external" or "agent",
        author={alias=reply.modelAlias or "",model=reply.model or ""}}
end
function Provenance:before(call, tool, attempt)
    attempt = attempt or {}
    local step = assert(attempt.stepId,"provenance needs the model reply's stepId")
    if self.state.stepId ~= step then
        self.state.stepId, self.state.sawGiven = step, self.state.given
    end
    if attempt.foreign then self.state.external=true end
    local given, lowered = self.state.sawGiven, nil
    for _, url in ipairs(addresses_of(call)) do
        if url ~= "" and not given:find(url,1,true) then
            lowered = lowered or lower_schemes(given)
            if not lowered:find(lower_schemes(url),1,true) then
                return nil,"The address " .. url .. " was not given by a person, a source or a tool. Use an address from the supplied material or read a source that provides it."
            end
        end
    end
    if not tool then return true end
    local policy, args = tool.provenance, decoded_args(call)
    if not object(args) or (policy ~= "whole" and not (policy == "quarantine" and self.state.external)) then return true end
    local context = self:context(attempt.reply)
    local marks = {origin=context.origin}
    if policy == "whole" then marks.author=context.author end
    local oldOrigin = args.origin
    local raw = call.arguments or json.encode(args)
    local marked = mark_arguments(raw,marks)
    -- Invalid arguments are the registry/tool's model-facing error. Do not
    -- manufacture a runnable request from malformed original JSON.
    if not marked then return true end
    for key,value in pairs(marks) do args[key]=value end
    call.args, call.arguments = args, marked
    call.quarantined = policy == "quarantine" and oldOrigin ~= "external" or nil
    return true
end
function Provenance:heard(call, result)
    local tool = result.tool or self:_tool(call.name)
    if not tool then return end
    if not tool.bringsNothingIn then self.state.external=true end
    local raw = object(result.raw) and result.raw or {}
    local answer = text(result.output)
    if composes(tool,decoded_args(call)) then
        for _, step in ipairs(raw.steps or {}) do
            local source = self:_tool(step.title)
            if source and not step.isError then self:_hand(self:_recorded(source,{arguments=step.quoted},step.body)) end
        end
    elseif tool.echoes then self:_hand(raw.given)
    elseif tool.kept then self:_hand(addresses_in(answer) .. json_addresses(answer))
    else self:_hand(data_given(answer)) end
end

return Provenance
