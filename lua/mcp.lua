-- MCP revisions and trust rules mirror agent/internal/tool/mcpx and mcpwire.
-- Transport results remain intact; the core owns execution policy and files.
local json = require("json")
local core = require("asenta.core")
local process = require("asenta.process")
local http = require("asenta.http")
local fs = require("asenta.fs")
local M = {revision="2026-07-28"}
local Connection = {}
Connection.__index = Connection
local protocolKey = "io.modelcontextprotocol/protocolVersion"
local serverKey = "io.modelcontextprotocol/serverInfo"
local inherited = {"PATH", "HOME", "TMPDIR", "TEMP", "TMP", "LANG", "LC_ALL", "LC_CTYPE",
    "USER", "LOGNAME", "SHELL", "TERM", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME",
    "XDG_RUNTIME_DIR", "SYSTEMROOT", "SYSTEMDRIVE", "APPDATA", "LOCALAPPDATA", "USERPROFILE",
    "PROGRAMDATA", "COMSPEC", "PATHEXT"}
local ranks = {read=1, write_local=2, exec=3, attended=4, external=5, physical=6}

local function object(value) return type(value) == "table" and value ~= json.null end
local function mapping(value) return setmetatable(value or {}, {__jsontype="object"}) end
local function copy(value)
    local result = mapping()
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end
local function equal(a, b)
    if a == b then return true end
    if not object(a) or not object(b) then return false end
    for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local function atLeast(value, floor)
    return ranks[value] >= ranks[floor] and value or floor
end
local function class(hints)
    hints = hints or {}
    if hints.physicalHint == true then return "physical" end
    if hints.readOnlyHint == true then return "read" end
    if hints.openWorldHint ~= false or hints.destructiveHint ~= false then return "external" end
    return "write_local"
end
local function nativeName(alias, name)
    for _, separator in ipairs({".", "/", "_"}) do
        if name:sub(1, #alias + 1) == alias .. separator then return name end
    end
    return alias .. "/" .. name
end
local function dirname(path) return path:match("^(.*)/[^/]+$") or "." end
local function basename(path) return path:match("([^/]+)$") end
local function join(directory, name) return directory:gsub("/$", "") .. "/" .. name end
local function log(self, text)
    if self.options.log then self.options.log("MCP " .. self.spec.alias .. ": " .. text) end
end
local function rootAt(directory, create)
    if not directory or directory == "" then return nil end
    local ok, root = pcall(fs.root, directory, create or false)
    return ok and root or nil
end
local function readJSON(root, path)
    local body, reason = root:read(path, 4 * 1024 * 1024)
    if not body then return nil, reason end
    local ok, value = pcall(json.decode, body)
    return ok and object(value) and value or nil, ok and nil or tostring(value)
end

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function headerValue(value)
    value = tostring(value)
    if value ~= "" and not value:find("[^ -~]") and not value:match("^%s") and
        not value:match("%s$") and value:sub(1, 9) ~= "=?base64?" then return value end
    local encoded = {}
    for i = 1, #value, 3 do
        local a, b, c = value:byte(i, i + 2)
        local n = (a << 16) | ((b or 0) << 8) | (c or 0)
        encoded[#encoded + 1] = alphabet:sub((n >> 18) + 1, (n >> 18) + 1) ..
            alphabet:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1) ..
            (b and alphabet:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) or "=") ..
            (c and alphabet:sub((n & 63) + 1, (n & 63) + 1) or "=")
    end
    return "=?base64?" .. table.concat(encoded) .. "?="
end

local function mirrors(schema, path, taken, result)
    path, taken, result = path or {}, taken or {}, result or {}
    for name, property in pairs(schema.properties or {}) do
        local here = {table.unpack(path)}
        here[#here + 1] = name
        if object(property) then
            local marked = property["x-mcp-header"]
            if marked ~= nil then
                assert(type(marked) == "string" and marked ~= "" and
                    not marked:find("[^%w!#$%%&'*+%.%^_`|~%-]"), "invalid x-mcp-header name")
                assert(not taken[marked:lower()], "duplicate x-mcp-header name")
                assert(property.type == "string" or property.type == "integer" or
                    property.type == "boolean", "invalid x-mcp-header type")
                taken[marked:lower()] = true
                result[#result + 1] = {name=marked, path=here}
            end
            mirrors(property, here, taken, result)
        end
    end
    return result
end

function Connection:_envelope(method, params, notification)
    params = copy(params)
    if not self.legacy then
        params._meta = {[protocolKey]=M.revision,
            ["io.modelcontextprotocol/clientInfo"]={name="oxtorg-agent", version="0.1.0"},
            ["io.modelcontextprotocol/clientCapabilities"]=mapping()}
    end
    local request = {jsonrpc="2.0", method=method, params=params}
    if not notification then self.serial = self.serial + 1; request.id = self.serial end
    return request
end

function Connection:_notice(message)
    if message.method == "notifications/tools/list_changed" then self.changed = true end
end

function Connection:_exchange(request, marked)
    local body = json.encode(request)
    if self.child then
        local untilMs = core.monotonic_ms() + self.timeout
        local sent, reason = self.child:send(body .. "\n", self.timeout)
        assert(sent, "MCP write: " .. tostring(reason))
        if not request.id then return end
        repeat
            local left = math.max(0, untilMs - core.monotonic_ms())
            local line, why = self.child:receive(left, self.maximum)
            assert(line, "MCP response: " .. tostring(why))
            local message = json.decode(line)
            if message.method then
                if message.id == nil then self:_notice(message) end
            elseif message.id == request.id or message.id == nil or message.id == json.null then
                return message
            else
                log(self, "discarded response to request " .. tostring(message.id))
            end
        until core.monotonic_ms() >= untilMs
        error("MCP response: timeout")
    end
    local headers = {Accept="application/json, text/event-stream", ["Mcp-Method"]=request.method,
        ["MCP-Protocol-Version"]=self.protocol or M.revision}
    if request.params.name then headers["Mcp-Name"] = headerValue(request.params.name) end
    if self.session then headers["Mcp-Session-Id"] = self.session end
    for _, mirror in ipairs(marked or {}) do
        local value = request.params.arguments
        for _, key in ipairs(mirror.path) do value = object(value) and value[key] or nil end
        if type(value) == "string" or type(value) == "boolean" or
            (type(value) == "number" and value % 1 == 0) then
            headers["Mcp-Param-" .. mirror.name] = headerValue(value)
        end
    end
    local held, reply, streamed = "", nil, nil
    local event = {}
    local function accept(message)
        if message.method then self:_notice(message); return true end
        assert(message.id == request.id or message.id == nil or message.id == json.null,
            "MCP response has another request ID")
        reply = message
        return false
    end
    local function consume(chunk)
        held = held .. chunk
        assert(#held <= self.maximum, "MCP response exceeds maxBytes")
        if streamed == nil and held:find("%S") then streamed = not held:match("^%s*{") end
        if not streamed then
            local ok, message = pcall(json.decode, held)
            if ok then return accept(message) end
            return true
        end
        while true do
            local line, rest = held:match("^(.-)\n(.*)$")
            if not line then return true end
            held = rest
            line = line:gsub("\r$", "")
            if line == "" and #event > 0 then
                local message = json.decode(table.concat(event, "\n"))
                event = {}
                if not accept(message) then return false end
            elseif line:sub(1, 5) == "data:" then
                event[#event + 1] = line:sub(6):gsub("^ ", "")
            end
        end
    end
    local status, response, rawHeaders = http.request{method="POST", url=self.spec.url,
        token=self.token, body=body, headers=headers, timeoutMs=self.timeout,
        maxBytes=self.maximum, caFile=self.options.caFile,
        consume=request.id and consume or nil}
    assert(status, "MCP HTTP: " .. tostring(response))
    for name, value in tostring(rawHeaders or ""):gmatch("([^\r\n:]+):[ \t]*([^\r\n]*)") do
        if name:lower() == "mcp-session-id" then self.session = value end
    end
    assert(status ~= 401, "MCP server did not accept the token")
    if not request.id then assert(status < 300, "MCP notification HTTP " .. status); return end
    if not reply and response and response ~= "" and held == "" then consume(response) end
    if not reply and not streamed and held ~= "" then reply = json.decode(held) end
    assert(reply, "MCP HTTP " .. status .. " returned no RPC response")
    return reply
end

function Connection:_rpc(method, params, marked)
    local request = self:_envelope(method, params)
    local response = self:_exchange(request, marked)
    if object(response.error) then
        error(setmetatable(response.error, {__tostring=function(e)
            return "MCP " .. tostring(e.code) .. ": " .. tostring(e.message)
        end}), 0)
    end
    assert(response.result ~= nil and response.result ~= json.null,
        "MCP response contains neither result nor error")
    return response.result
end

function Connection:_discover()
    local ok, result = pcall(self._rpc, self, "server/discover")
    if not ok then
        if not object(result) or (result.code ~= -32601 and result.code ~= -32022) then error(result, 0) end
        local revision = "2025-06-18"
        if result.code == -32022 then
            revision = nil
            for _, offered in ipairs((result.data or {}).supported or {}) do
                if offered < M.revision and (not revision or offered > revision) then revision = offered end
            end
            assert(revision, "MCP server has no compatible protocol revision")
        end
        self.legacy = true
        result = self:_rpc("initialize", {protocolVersion=revision, capabilities=mapping(),
            clientInfo={name="oxtorg-agent", version="0.1.0"}})
        self.protocol = result.protocolVersion or revision
        self:_exchange(self:_envelope("notifications/initialized", {}, true))
        self.info = result.serverInfo or {}
    else
        self.info = (result._meta or {})[serverKey] or {}
    end
    if self.spec.url and self.passport and not self.spec.own and self.info.name ~= self.passport.name then
        self.own = false
        log(self, "server name differs from its passport")
    end
end

local function declaration(info)
    return {name=info.name, title=info.title, description=info.description,
        inputSchema=info.inputSchema, annotations=info.annotations}
end

function Connection:_accepted()
    if not self.pins then return self.accepted end
    local file = "accepted/" .. self.spec.alias .. ".json"
    local exists, why = self.pins:stat(file)
    if not exists then return why and {} or nil end
    local kept = readJSON(self.pins, file)
    if not kept then return {} end
    if kept.server ~= self.reach then return nil end
    return kept.accepted or {}
end

function Connection:_list()
    local infos, cursor, cursors = {}, nil, {}
    for _ = 1, 50 do
        local result = self:_rpc("tools/list", {cursor=cursor})
        assert(object(result.tools), "MCP tools/list has no tools array")
        for _, info in ipairs(result.tools) do infos[#infos + 1] = info end
        cursor = result.nextCursor
        if not cursor or cursor == "" or cursor == json.null then break end
        assert(not cursors[cursor], "MCP tool list repeats a cursor")
        cursors[cursor] = true
    end
    assert(not cursor or cursor == "" or cursor == json.null, "MCP tool list exceeds 50 pages")
    local accepted = not self.own and self:_accepted() or nil
    local nextAccepted, pending, offered, held, seen = mapping(), mapping(), json.array(), json.array(), {}
    self.marked = {}
    for _, info in ipairs(infos) do
        assert(type(info.name) == "string" and not seen[info.name], "MCP tool name is missing or duplicated")
        seen[info.name] = true
        local current, selected, floor = declaration(info), info, "read"
        if not self.own then
            local previous = accepted and accepted[info.name]
            if accepted and (not previous or not equal(previous, current)) then
                held[#held + 1], pending[info.name] = info.name, current
                selected, floor = previous, class(info.annotations)
            end
            if selected then nextAccepted[info.name] = declaration(selected) end
        end
        if selected then
            local ok, marked = pcall(mirrors, selected.inputSchema or {})
            if ok then
                local hints = selected.annotations or {}
                local risk = atLeast(class(hints), floor)
                if not self.own then risk = atLeast(risk, "external") end
                local foreign = true
                if self.own then
                    if type(hints.foreignTextHint) == "boolean" then foreign = hints.foreignTextHint
                    else foreign = hints.openWorldHint ~= false end
                end
                local rawName = selected.name
                local description = selected.description or ""
                if selected.title and description:sub(1, #selected.title) ~= selected.title then
                    description = selected.title .. ". " .. description
                end
                self.marked[rawName] = marked
                local tool = {name=nativeName(self.spec.alias, rawName),
                    title=selected.title, description=description, parameters=selected.inputSchema or {},
                    class=risk, foreign=foreign, polling=self.own and hints.pollingHint == true,
                    source=self.spec.alias, program=self.program,
                    invoke=function(args) return self:call(rawName, args) end}
                offered[#offered + 1] = self.options.declarationRoot and
                    require("sequence").fields(self.options.declarationRoot,tool,{"description","parameters"}) or tool
            else log(self, "tool " .. selected.name .. " was omitted: " .. tostring(marked)) end
        end
    end
    table.sort(offered, function(a, b) return a.name < b.name end)
    table.sort(held)
    self.offered, self.held, self.changed = offered, held, false
    if not self.own then
        self.accepted = nextAccepted
        if self.pins then
            local ok, why = self.pins:write("accepted/" .. self.spec.alias .. ".json",
                json.encode{server=self.reach, accepted=nextAccepted, pending=pending})
            if not ok then log(self, "cannot retain accepted declarations: " .. tostring(why)) end
        end
    end
end

function Connection:call(rawName, args)
    assert(self.connected and not self.closed, self.reason or "MCP server is disconnected")
    return self:_rpc("tools/call", {name=rawName, arguments=copy(args)}, self.marked[rawName])
end

function Connection:tools(refresh)
    if self.connected and (refresh or self.changed) then self:_list() end
    return self.offered
end

function Connection:report()
    if self.connected and self.child and not self.closed then
        local code = self.child:status()
        if code ~= nil then self.connected, self.reason = false, "process exited with status " .. code end
    end
    local declared = json.array()
    for _, tool in ipairs(self.offered) do declared[#declared + 1] = {name=tool.name, title=tool.title} end
    return {alias=self.spec.alias, name=self.info.name, title=self.info.title,
        tools=#self.offered, connected=self.connected, reason=self.reason,
        missing=self.missing, declared=declared, held=self.held, unconfined=self.child ~= nil}
end

function Connection:close()
    if self.child then self.child:close() end
    if self.pins then self.pins:close(); self.pins = nil end
    self.closed, self.connected = true, false
end

local function prepare(self)
    local spec, options = self.spec, self.options
    assert(type(spec.alias) == "string" and spec.alias ~= "", "MCP alias is required")
    assert(not spec.package, "MCP bundles require the installed package resolver")
    assert((spec.command ~= nil) ~= (spec.url ~= nil), "MCP requires exactly one command or url")
    self.own = spec.own == true
    local directory = rootAt(options.programDir)
    local command = spec.command
    if command and command:sub(1, 1) ~= "/" then
        if command:find("/", 1, true) then command = join(options.configDir or ".", command)
        elseif directory and directory:stat(command) then command = join(options.programDir, command) end
    end
    local passportName = spec.url and spec.alias or nil
    if command then
        passportName = basename(command):gsub("%.exe$", ""):match("^oxtorg%-mcp%-(.+)$")
        if dirname(command) ~= options.programDir then passportName = nil end
        local source = rootAt(dirname(command))
        if source then self.program = source:hash(basename(command)); source:close() end
    end
    if directory and passportName then
        self.passport = readJSON(directory, "oxtorg-mcp-" .. passportName .. ".passport.json")
    end
    if directory then directory:close() end
    if self.passport then
        if spec.url then self.own, self.program = true, self.passport.sha256
        elseif self.passport.sha256 and self.passport.sha256 ~= "" then
            assert(self.program == self.passport.sha256, "MCP binary differs from its passport SHA256")
            self.own = true
        end
    end
    local env = {}
    for _, name in ipairs(inherited) do env[name] = os.getenv(name) end
    for name, value in pairs(spec.env or {}) do env[name] = value end
    for name, variable in pairs(spec.envFrom or {}) do
        local value = os.getenv(variable)
        if not value or value == "" then self.missing[#self.missing + 1] = variable else env[name] = value end
    end
    if spec.url then
        assert(type(spec.tokenEnv) == "string", "MCP HTTP requires tokenEnv")
        self.token = os.getenv(spec.tokenEnv)
        if not self.token or self.token == "" then self.missing[#self.missing + 1] = spec.tokenEnv end
    end
    table.sort(self.missing)
    assert(#self.missing == 0, "missing environment: " .. table.concat(self.missing, ", "))
    env.OXTORG_TOOL_OUTPUT = tostring(options.toolOutput or 24 * 1024)
    if command then
        local argv = {command}
        for _, value in ipairs(spec.args or {}) do argv[#argv + 1] = value end
        self.child = process.spawn{argv=argv, env=env, cwd=spec.cwd,
            stdoutBytes=self.maximum + 16384, stderrBytes=options.stderrBytes or 65536}
    end
    self.reach = spec.url or table.concat({spec.command, table.unpack(spec.args or {})}, " ")
    self:_discover()
    if not self.own and spec.alias:match("^[A-Za-z0-9._-]+$") and #spec.alias <= 64 and
        spec.alias:find("[^.]") then self.pins = rootAt(options.mcpRoot or os.getenv("OXTORG_MCP"), true) end
    self:_list()
    self.connected = true
end

function M.connect(spec, options)
    options = options or {}
    local self = setmetatable({spec=spec, options=options, serial=0, connected=false, info={},
        offered=json.array(), held=json.array(), missing=json.array(),
        timeout=options.timeoutMs or 180000, maximum=options.maxBytes or 72 * 1024 * 1024}, Connection)
    local ok, reason = pcall(prepare, self)
    if not ok then
        self.reason = tostring(reason)
        if self.child then self.child:close() end
        if self.pins then self.pins:close(); self.pins = nil end
        log(self, self.reason)
    end
    return self
end

return M
