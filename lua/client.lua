local json = require("json")
local core = require("asenta.core")
local http = require("asenta.http")
local Client = {}
Client.__index = Client
local errorType = {__tostring=function(e)
    return e.message or e.reason or (e.status and "HTTP " .. e.status) or "transport failed"
end}
local function fail(value) error(setmetatable(value, errorType), 0) end
local function copy(value)
    local out = {}
    for k, v in pairs(value or {}) do out[k] = v end
    return out
end
function Client.escape(text)
    return text:gsub("[^%w%-._~]", function(c) return string.format("%%%02X", c:byte()) end)
end

function Client.new(config)
    return setmetatable({config=config, prefix=core.identifier(), serial=0, readUpTo=0}, Client)
end

-- Each attempt owns its version and read boundary, including when several
-- attempts eventually share the scheduler. No task state lives in the transport.
function Client:for_task(taskId)
    local client = Client.new(self.config)
    client.path = "/api/v1/tasks/" .. Client.escape(taskId)
    return client
end

function Client:request(method, path, value, model, options)
    options = options or {}
    local config, endpoint = self.config, self.config.server
    local key, base = endpoint.tokenEnv, endpoint.baseUrl
    if model then
        endpoint = assert(config.model, "model configuration is required")
        if endpoint.via == "server" then
            assert(not endpoint.baseUrl or endpoint.baseUrl == "", "model baseUrl conflicts with via=server")
            assert(not endpoint.keyEnv or endpoint.keyEnv == "", "model keyEnv conflicts with via=server")
            base = os.getenv("OXTORG_MODEL_DOOR") or base:gsub("/$", "") .. "/model"
        else
            key, base = endpoint.keyEnv, endpoint.baseUrl
        end
    end
    local token = key and assert(os.getenv(key), "missing credential variable: " .. key)
    local transport = config.transport or {}
    local request = {method=method, url=assert(base, "endpoint is required"):gsub("/$", "") .. path,
        token=token, body=options.rawBody, caFile=transport.caFile,
        timeoutMs=options.timeoutMs or transport.timeoutMs,
        maxBytes=options.maxBytes or transport.maxBytes or 32*1024*1024, headers=options.headers, consume=options.consume}
    if options.rawBody == nil and value ~= nil then request.bodyReader,request.bodyBytes=json.reader(value) end
    local status, body, headers = http.request(request)
    -- A paid turn is never replayed. A streaming consumer has already observed
    -- data, so its caller controls restarting rather than receiving duplicates.
    if method == "GET" and not options.consume and (not status or status >= 500) then
        if request.bodyReader then request.bodyReader,request.bodyBytes=json.reader(value) end
        status, body, headers = http.request(request)
    end
    if not status then fail({message="transport: " .. tostring(body), headers=headers}) end
    local ok, decoded = true, {}
    if body ~= "" then ok, decoded = pcall(json.decode, body) end
    if not (status >= 200 and status < 300) and not (options.allowStatus or {})[status] then
        local obj = ok and type(decoded) == "table" and decoded or {}
        local detail = type(obj.error) == "table" and obj.error.message or obj.error
        fail({status=status, reason=obj.reason, message=detail or "HTTP " .. status .. " at " .. path,
            body=obj, rawBody=body, headers=headers, gateway=obj.reason == nil and type(obj.error) == "table"})
    end
    if not ok then fail({status=status, message="invalid JSON at " .. path, rawBody=body}) end
    return decoded, status, headers
end

function Client:lease(taskId)
    if taskId then self.path = "/api/v1/tasks/" .. Client.escape(taskId) end
    local reply = self:request("POST", assert(self.path, "task is required") .. "/lease")
    local task = reply.task
    if task.state == "canceled" then fail({reason="task_canceled",message="task was canceled",certainty="not_started"}) end
    self.version = assert(task.version, "missing task version")
    self.readBound = reply.readBound
    self.leasedAt = core.monotonic_ms()
    return task
end

function Client:history(root)
    local result, after, size = root and require("sequence").new(root) or {}, 0, 0
    local transport=self.config.transport or {}
    local limit=transport.historyMaxBytes or transport.maxBytes
    repeat
        local function accept(event)
            result[#result + 1] = event
            size = size + #json.encode(event)
            assert(not limit or size <= limit, "history exceeds maxBytes")
        end
        local options={maxBytes=transport.maxBytes or 32*1024*1024}
        local parser
        if root then
            parser=require("snapshot_stream").new(accept,"events")
            options.consume=function(chunk) parser:feed(chunk) end
        end
        local page = self:request("GET", self.path .. "/events?after=" .. after,nil,false,options)
        if parser then page=parser:finish()
        else for _,event in ipairs(page.events) do accept(event) end end
        self.readUpTo = page.cursor or after
        if not page.hasMore then return result end
        assert(self.readUpTo > after, "history cursor did not advance")
        after = self.readUpTo
    until false
end

function Client:prepare(event, requestId)
    local wire = copy(event)
    if not wire.requestId then
        self.serial = self.serial + 1
        wire.requestId = requestId or self.prefix .. "/" .. self.serial
    end
    if wire.version == nil then wire.version = self.version end
    if wire.readUpTo == nil then wire.readUpTo = self.readUpTo end
    return wire
end

-- Persist prepare() before sending. Replaying the prepared object retains its
-- original version/read boundary: a conflict cannot authorize an old action.
function Client:append(event)
    local reply = self:request("POST", self.path .. "/events", self:prepare(event))
    self.version = assert(reply.version, "missing written version")
    return reply.event
end

return Client
