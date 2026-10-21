-- Lua shelf tools are ordinary programs in separate processes. They have the
-- agent's OS privileges; no Lua sandbox or source filtering is implied here.
local json, fs, process, core = require("json"), require("asenta.fs"), require("asenta.process"), require("asenta.core")
local Client = require("client")
local Workshop = {}
Workshop.__index = Workshop
local function map(value) return setmetatable(value or {}, {__jsontype="object"}) end
local function trim(value) return (value or ""):match("^%s*(.-)%s*$") end
local function copy(value)
    local result = map()
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end
local function array(value)
    local result = json.array()
    for _, item in ipairs(value or {}) do result[#result + 1] = item end
    return result
end
local function join(base, path) return base:gsub("/$", "") .. "/" .. path end
local function now() return os.date("!%Y-%m-%dT%H:%M:%SZ") end
local function validName(name)
    return type(name) == "string" and #name >= 2 and #name <= 40 and name:match("^[a-z][a-z0-9_-]*$")
end
local function validSource(name)
    return type(name) == "string" and #name <= 64 and name:match("^[a-z0-9][a-z0-9._-]*$") and
        name ~= "tool.json" and name ~= "data" and name ~= "machine.json" and not name:match("%.writing$")
end
local function answer(value, message, failed)
    return {isError=failed or false, content=json.array({{type="text", text=message or json.encode(value)}}), structuredContent=value}
end
local function failure(reason)
    local detail = type(reason) == "table" and reason or {}
    local message = detail.message or tostring(reason)
    return answer({error=message, reason=detail.reason, outcomeUnknown=detail.outcomeUnknown}, message, true)
end
local function schema(properties, required)
    return {type="object", properties=map(properties), additionalProperties=false, required=json.array(required)}
end

-- Go's review projection is byte-sensitive. Keep its field order, indentation
-- and HTML escaping, so installed Go reviews name the same program in Lua.
local function ordered(value, order) return setmetatable(value, {order=order}) end
local function pretty(value, depth)
    depth = depth or 0
    if type(value) ~= "table" or value == json.null then
        return json.encode(value):gsub("<", "\\u003c"):gsub(">", "\\u003e"):gsub("&", "\\u0026"):
            gsub("\226\128\168", "\\u2028"):gsub("\226\128\169", "\\u2029")
    end
    local meta, parts = getmetatable(value) or {}, {}
    local isArray = meta.__jsontype == "array" or #value > 0
    local keys = meta.order or {}
    if not isArray and not meta.order then for key in pairs(value) do keys[#keys + 1] = key end; table.sort(keys) end
    local indent = string.rep("  ", depth + 1)
    if isArray then
        for _, item in ipairs(value) do parts[#parts + 1] = indent .. pretty(item, depth + 1) end
    else
        for _, key in ipairs(keys) do
            if value[key] ~= nil then parts[#parts + 1] = indent .. pretty(key) .. ": " .. pretty(value[key], depth + 1) end
        end
    end
    local open, close = isArray and "[" or "{", isArray and "]" or "}"
    if #parts == 0 then return open .. close end
    return open .. "\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep("  ", depth) .. close
end
local function reviewed(spec)
    local params = json.null
    if spec.card.params ~= nil and spec.card.params ~= json.null then
        params = json.array()
        for _, param in ipairs(spec.card.params) do
            params[#params + 1] = ordered({name=param.name or "", description=param.description or "", required=param.required == true},
                {"name", "description", "required"})
        end
    end
    local card = spec.card
    local projection = ordered({name=card.name, summary=card.summary or "", environment=card.environment or "", params=params,
        network=card.network == true, env=#(card.env or {}) > 0 and array(card.env) or nil,
        reads=#(card.reads or {}) > 0 and array(card.reads) or nil}, {"name", "summary", "environment", "params", "network", "env", "reads"})
    local files = json.array({{name="tool.json", text=pretty(projection)}})
    for _, file in ipairs(spec.sources) do files[#files + 1] = {name=file.name, text=file.text} end
    return files
end
local function digest(files)
    local pieces = {}
    for _, file in ipairs(files) do pieces[#pieces + 1] = #file.name .. ":" .. file.name .. "\0" .. #file.text .. ":" .. file.text end
    return fs.sha256(table.concat(pieces))
end
local function loadSpec(name, read)
    assert(validName(name), "invalid tool name")
    local raw = assert(read("tool.json"), "tool card is missing")
    local card = json.decode(raw)
    card.name = name
    local names = card.files
    if not names or #names == 0 then names = {card.script} end
    assert(#names > 0 and #names <= 32 and (not card.script or card.script == names[1]), "inconsistent tool entry point")
    local sources, seen = json.array(), {}
    for _, filename in ipairs(names) do
        assert(validSource(filename) and not seen[filename], "invalid or duplicate source filename")
        seen[filename] = true
        sources[#sources + 1] = {name=filename, text=assert(read(filename), "source is missing: " .. filename)}
    end
    local spec = {card=card, raw=raw, sources=sources}
    spec.reviewed = reviewed(spec)
    spec.digest = digest(spec.reviewed)
    local original = {{name="tool.json", text=raw}}
    for _, file in ipairs(sources) do original[#original + 1] = file end
    spec.sourceDigest = digest(original)
    return spec
end

local bootstrap = [=[
assert(_VERSION == "Lua 5.5", "Lua 5.5 is required")
local codec = require("dkjson")
local requestText = assert(io.read("*l"), "missing Lua request")
local request, _, why = codec.decode(requestText, 1, codec.null)
assert(not why, why)
local marker, stdout = request.marker, io.stdout
local function outputValue(value, active)
    if type(value) ~= "table" or value == codec.null then return value end
    assert(not active[value], "result contains a cycle")
    active[value] = true
    local count, numeric = 0, true
    for key in pairs(value) do count=count+1; numeric=numeric and type(key)=="number" and key>=1 and key%1==0 end
    local isArray = (numeric and count>0) or (getmetatable(value) or {}).__jsontype == "array"
    assert(not isArray or numeric and count == #value, "result array contains holes or mixed keys")
    local result = setmetatable({}, {__jsontype=isArray and "array" or "object"})
    for key, item in pairs(value) do
        assert(isArray or type(key)=="string", "result object keys must be strings")
        result[key] = outputValue(item, active)
    end
    active[value] = nil
    return result
end
local function run()
    local chunks, loaded, loading = {}, {}, {}
    json = {null=codec.null, encode=function(value) return assert(codec.encode(outputValue(value, {}))) end,
        decode=function(value) local result, _, err=codec.decode(value,1,codec.null); assert(not err,err); return result end,
        array=function(value) return setmetatable(value or {}, {__jsontype="array"}) end}
    for _, source in ipairs(request.sources) do chunks[source.name] = assert(load(source.text, "@" .. source.name, "t", _G)) end
    if request.check then return "" end
    local system_require = require
    require = function(name)
        local filename = chunks[name] and name or name:gsub("%.", "/") .. ".lua"
        if not chunks[filename] then return system_require(name) end
        if loaded[filename] ~= nil then return loaded[filename] end
        assert(not loading[filename], "cyclic source import: " .. name)
        loading[filename] = true
        local value = chunks[filename]()
        loaded[filename], loading[filename] = value == nil and true or value, nil
        return loaded[filename]
    end
    local entry = chunks[request.sources[1].name]()
    assert(type(entry) == "function", "entry source must return function(args)")
    local value = entry(request.args)
    local output = type(value) == "string" and value or json.encode(value)
    assert(#output <= request.outputLimit and utf8.len(output), "Lua output exceeds its limit or is not UTF-8")
    return output
end
local ok, output = pcall(run)
stdout:write("\n", marker, assert(codec.encode({ok=ok, output=tostring(output)})), "\n")
stdout:flush()
os.exit(ok and 0 or 1)
]=]

function Workshop.new(config, client, options)
    options, config = options or {}, config or {}
    local limits, off = config.limits or {}, trim(os.getenv("OXTORG_WORKSHOP_OFF"))
    local disabled = off ~= "" and off ~= "0" and off ~= "false" and off ~= "False" and off ~= "FALSE"
    local self = setmetatable({config=config, client=client, options=options, children={}, roots={}, cached={}, held={},
        enabled=limits.workshop == true and not disabled, lua=options.lua or (config.workshop or {}).lua or "lua5.5",
        output=limits.toolOutput or 24 * 1024, reserved={}}, Workshop)
    for _, name in ipairs(options.reserved or {}) do self.reserved[name] = true end
    local function reserve(name) if name and name ~= "" then self.reserved[name] = true end end
    reserve((config.server or {}).tokenEnv); reserve((config.model or {}).keyEnv)
    for _, server in ipairs(config.mcp or {}) do reserve(server.tokenEnv); for _, name in pairs(server.envFrom or {}) do reserve(name) end end
    if self.enabled then
        assert(limits.sandbox == "warn" or os.getenv("OXTORG_SANDBOX") == "warn", "workshop requires isolation; this Lua process adapter has none")
        self.base = options.root or os.getenv("OXTORG_WORKSHOP")
        self.runtime = options.stateRoot or config.stateRoot or ((limits.workRoot or "/tmp/asenta-agent") .. ".lua")
        if options.log then options.log("Lua workshop runs with the agent's OS privileges; sandbox=warn") end
    end
    return self
end

function Workshop:_root(path)
    if not self.roots[path] then self.roots[path] = assert(fs.root(path, true)) end
    return self.roots[path]
end
function Workshop:_scope(task, view)
    local owner = task.ownerId or ""
    assert(#owner <= 128 and owner:match("^[A-Za-z0-9][A-Za-z0-9_.-]*$"), "task owner cannot name a shelf")
    local base
    if view then
        base = join(self.runtime, "workshop/" .. fs.sha256((view.snapshot.workspaceId or "") .. "/" .. (view.snapshot.worktreeId or "") .. "/" .. owner))
    else base = join(assert(self.base, "OXTORG_WORKSHOP is required for a personal shelf"), owner) end
    local root = self:_root(base)
    assert(root:mkdir("tools"))
    local scope = {root=root, base=base, view=view, taskId=assert(task.taskId or task.id, "task is required")}
    function scope:read(name, file)
        local path = "tools/" .. name .. "/" .. file
        if self.view then
            for _, found in ipairs(self.view:list()) do if found == path then return self.view:read(path) end end
            return nil
        end
        return self.root:read(path, 1024 * 1024)
    end
    function scope:spec(name) return loadSpec(name, function(file) return self:read(name, file) end) end
    function scope:statePath(name)
        return self.view and "tools/" .. name .. "/runtime.json" or ".runtime/" .. name .. ".json"
    end
    function scope:state(name)
        local raw = self.root:read(self:statePath(name), 65536)
        return raw and json.decode(raw) or {}
    end
    function scope:save(name, state) assert(self.root:write(self:statePath(name), json.encode(state))) end
    return scope
end
function Workshop:_environment(card, data)
    local env = map()
    for _, name in ipairs({"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"}) do env[name] = os.getenv(name) end
    if data then env.OXTORG_TOOL_DATA = data end
    for _, name in ipairs(card.env or {}) do
        assert(not self.reserved[name] and name:sub(1,7) ~= "OXTORG_", "variable belongs to the agent: " .. name)
        if env[name] == nil then env[name] = assert(os.getenv(name), "missing variable: " .. name) end
    end
    return env
end
local function current(context) return type(context) == "function" and context() or context or {} end
function Workshop:_execute(spec, args, scope, context, check)
    local values = map()
    for name, value in pairs(args or {}) do
        assert(type(name) == "string", "tool arguments must be an object")
        if value ~= json.null then values[name] = type(value) == "string" and value or json.encode(value) end
    end
    if not check then
        for _, param in ipairs(spec.card.params or {}) do
            assert(not param.required or trim(values[param.name]) ~= "", "missing parameter: " .. param.name)
        end
    end
    local data = "tools/" .. spec.card.name .. "/data"
    local directory = current(context).workDir or (self.config.limits or {}).workRoot
    if not check then
        assert(directory and directory ~= "", "limits.workRoot is required to run a tool")
        directory = join(directory, scope.taskId)
        self:_root(directory)
        if not spec.skill then assert(scope.root:mkdir(data)) end
    else directory = "/" end
    local marker = "ASENTA-LUA-" .. core.identifier() .. ":"
    local request = {sources=spec.sources, args=values, outputLimit=self.output, check=check or false, marker=marker}
    local body = json.encode(request)
    assert(#body <= 1024 * 1024, "Lua input exceeds 1 MiB")
    local child = process.spawn{argv={self.lua, "-E", "-e", "package.path=" .. string.format("%q", package.path) .. ";\n" .. bootstrap},
        cwd=directory, env=self:_environment(check and {} or spec.card, not check and not spec.skill and join(scope.base, data) or nil),
        stdoutBytes=self.output * 6 + 4096, stderrBytes=self.output}
    self.children[child] = true
    local timeout = self.options.timeoutMs or (spec.card.network and 120000 or 30000)
    local expires = core.monotonic_ms() + timeout
    local ok, result = pcall(function()
        assert(child:send(body .. "\n", timeout), "could not send Lua request")
        local output, size = {}, 0
        while true do
            local ctx = current(context)
            if ctx.cancelled and ctx.cancelled() or core.monotonic_ms() >= expires then
                error({message="Lua execution interrupted; effects may have happened. Do not repeat the action without checking its outcome.", outcomeUnknown=true}, 0)
            end
            local line, reason = child:receive(math.min(100, math.max(0, expires - core.monotonic_ms())), self.output * 6 + 4096)
            if line then
                local at = line:find(marker, 1, true)
                if at then
                    local reply = json.decode(line:sub(at + #marker))
                    local preceding = table.concat(output, "\n"):gsub("\n$", "")
                    local combined = (preceding ~= "" and preceding .. "\n" or "") .. reply.output
                    assert(#combined <= self.output, "Lua output exceeds its limit")
                    return answer({output=combined, exitCode=reply.ok and 0 or 1, unconfined=true}, combined, not reply.ok)
                end
                output[#output + 1], size = line, size + #line + 1
                assert(size <= self.output, "Lua output exceeds its limit")
            elseif reason == "eof" then
                local code = child:status()
                error({message="Lua exited without its result (status " .. tostring(code) .. "): " .. child:stderr(), outcomeUnknown=code == 0}, 0)
            end
        end
    end)
    child:close(); self.children[child] = nil
    if not ok then
        if type(result) ~= "table" then result = {message=tostring(result)} end
        result.outcomeUnknown = true
        error(result, 0)
    end
    return result
end

function Workshop:_reviews()
    if not self.client then return self.cached end
    local ok, response = pcall(self.client.request, self.client, "GET", "/api/v1/me/tools/reviews")
    if ok then
        self.cached = {}
        for _, review in ipairs(response.tools or {}) do self.cached[review.name .. "/" .. review.digest] = review end
    else
        self.cached = {}
        if self.options.log then self.options.log("Cannot read tool reviews: " .. tostring(response)) end
    end
    return self.cached
end
function Workshop:_submit(spec, scope, context, built)
    assert(self.client, "there is no server for tool review")
    local ctx = current(context)
    assert(ctx.author and (trim(ctx.author.alias) ~= "" or trim(ctx.author.model) ~= ""), "trusted model author is required")
    local response = self.client:request("PUT", "/api/v1/me/tools/" .. Client.escape(spec.card.name) .. "/review", {
        files=spec.reviewed, basis=(built and "Built in task " .. scope.taskId or "Unreviewed shelf source") .. ": " .. spec.card.summary,
        origin=spec.card.origin == "external" and "external" or "agent", author=ctx.author, taskId=scope.taskId, built=built})
    local candidate = response.candidate
    if candidate then self.cached[spec.card.name .. "/" .. spec.digest] = {name=spec.card.name, digest=candidate.digest,
        state=candidate.state, taskId=scope.taskId, built=built} end
    return candidate
end
function Workshop:_build(scope, input, context)
    local ctx = current(context)
    assert(ctx.origin == "agent" or ctx.origin == "external", "trusted provenance is required")
    assert(ctx.author and (trim(ctx.author.alias) ~= "" or trim(ctx.author.model) ~= ""), "trusted model author is required")
    local name = trim(input.name):lower()
    assert(validName(name), "invalid tool name")
    assert(input.environment == "lua", "this workshop adapter supports Lua tools")
    assert(trim(input.summary) ~= "", "tool summary is required")
    local command, files = trim(input.command), input.files or {}
    assert((command ~= "") ~= (#files > 0), "provide command or files, not both")
    if command ~= "" then files = {{name="body.lua", text=command}} end
    assert(#files <= 32, "Lua source count exceeds 32")
    local previous = scope:read(name, "tool.json")
    local old = previous and json.decode(previous) or {}
    assert(not previous or old.author == "assistant", "a person's tool cannot be rewritten")
    local card = {name=name, summary=trim(input.summary), environment="lua", params=array(input.params), network=input.network == true,
        author="assistant", origin=ctx.origin, uses=old.uses or 0, updatedAt=now(), runs=input.runs or old.runs,
        env=input.env, reads=input.reads}
    local seen, sources = {}, json.array()
    for _, file in ipairs(files) do
        local filename, body = trim(file.name):lower(), trim(file.text)
        assert(validSource(filename) and not seen[filename], "invalid or duplicate source filename")
        assert(#body > 0 and #body <= 20000 and utf8.len(body), "source must be nonempty UTF-8 within 20000 bytes")
        assert(load(body, "@" .. filename, "t", {})) -- Compile only; source statements are not executed here.
        seen[filename] = true
        sources[#sources + 1] = {name=filename, text=body}
    end
    for _, param in ipairs(card.params) do assert(trim(param.name) ~= "", "parameter name is required") end
    for _, variable in ipairs(card.env or {}) do
        assert(variable:match("^[A-Z][A-Z0-9_]*$") and not self.reserved[variable] and variable:sub(1,7) ~= "OXTORG_", "invalid or reserved environment variable")
    end
    card.script = sources[1].name
    if #sources > 1 then card.files=json.array(); for _, file in ipairs(sources) do card.files[#card.files+1]=file.name end end
    local spec = {card=card, sources=sources}
    local checked = self:_execute(spec, {}, scope, context, true)
    assert(not checked.isError, checked.content[1].text)
    local function write(file, body)
        local path = "tools/" .. name .. "/" .. file
        if scope.view then scope.view:write(path, body)
        elseif body then assert(scope.root:write(path, body))
        elseif scope.root:stat(path) then assert(scope.root:remove(path)) end
    end
    if scope.view then scope.view:set_provenance(ctx.author, ctx.origin) end
    for _, file in ipairs(sources) do write(file.name, file.text) end
    local removed = old.files or (old.script and {old.script}) or {}
    for _, file in ipairs(removed) do if validSource(file) and not seen[file] then write(file, nil) end end
    write("tool.json", json.encode(card) .. "\n")
    spec = scope:spec(name)
    local state = scope:state(name)
    state.builtTask, state.builtDigest, state.retiredAt = scope.taskId, spec.sourceDigest, nil
    scope:save(name, state)
    local value = {name="own." .. name, program=spec.digest, state=scope.view and "draft" or "built"}
    if not scope.view then
        local ok, candidate = pcall(self._submit, self, spec, scope, context, true)
        if ok then value.candidate = candidate else value.reviewError = tostring(candidate) end
    end
    return answer(value)
end

local buildSchema = schema({name={type="string"}, summary={type="string"}, environment={type="string", enum=json.array({"lua"})},
    network={type="boolean"}, env={type="array", items={type="string"}}, reads={type="array", items={type="string"}}, command={type="string"},
    files={type="array", items=schema({name={type="string"}, text={type="string"}}, {"name", "text"})},
    params={type="array", items=schema({name={type="string"}, description={type="string"}, required={type="boolean"}}, {"name", "description"})},
    runs={type="array", items=schema({title={type="string"}, prompt={type="string"}}, {"title", "prompt"})}}, {"name", "summary", "environment"})

function Workshop:tools(task, view, context)
    local tools = json.array()
    if not self.enabled then return tools end
    context = context or self.options.context
    local scope = self:_scope(task, view)
    tools[1] = {name="build_tool", class="write_local", group="oxtorg-native", source="", foreign=false,
        provenance="whole", growsShelf=true, parameters=buildSchema,
        description="Build a Lua tool. Sources return function(args), with string arguments; sibling files can be required. Standard Lua libraries are available. OXTORG_TOOL_DATA keeps persistent tool data. Runs in a separate process with the agent's OS privileges.",
        invoke=function(input) local ok, result=pcall(self._build,self,scope,input,context); return ok and result or failure(result) end}
    local names = {}
    if view then
        for _, path in ipairs(view:list()) do local name=path:match("^tools/([^/]+)/tool%.json$"); if name then names[#names+1]=name end end
    else for _, file in ipairs(assert(scope.root:list("tools"))) do if file.kind == "directory" then names[#names+1]=file.name end end end
    table.sort(names)
    local reviews = not view and self:_reviews() or {}
    self.held = {}
    for _, name in ipairs(names) do
        local ok, spec = pcall(scope.spec, scope, name)
        local admitted, why = false, nil
        if ok and spec.card.environment == "lua" then
            local state = scope:state(name)
            if view then
                local loaded, published = pcall(loadSpec, name, function(file) return view:published("tools/" .. name .. "/" .. file) end)
                admitted = loaded and view.revision ~= "" and published.sourceDigest == spec.sourceDigest or
                    state.builtTask == scope.taskId and state.builtDigest == spec.sourceDigest
            else
                local review = reviews[name .. "/" .. spec.digest]
                admitted = review and (review.state == "admitted" or (review.built and review.taskId == scope.taskId and
                    (review.state == "pending" or review.state == "running")))
                if not review then
                    local submitted, reason = pcall(self._submit,self,spec,scope,context,false)
                    if not submitted then why=tostring(reason) end
                end
            end
            local retired = state.retiredAt or spec.card.retiredAt
            if retired and retired ~= "" then admitted=false; why="tool is retired" end
        else why = ok and "environment is unavailable in this Lua workshop" or tostring(spec) end
        if admitted then
            local properties, required = {}, json.array()
            for _, param in ipairs(spec.card.params or {}) do
                properties[param.name] = {type="string", description=param.description}
                if param.required then required[#required+1]=param.name end
            end
            local native = "own." .. name
            tools[#tools+1] = {name=native, description=spec.card.summary, class=spec.card.network and "external" or "exec",
                parameters=schema(properties, required), foreign=spec.card.network == true, source=spec.card.network and native or "",
                group="workshop", program=spec.digest, built=true, composes=true,
                invoke=function(args)
                    local ok, value = pcall(function()
                        local latest = view and spec or scope:spec(name)
                        assert(latest.digest == spec.digest, "tool sources changed after they were offered")
                        local started = core.monotonic_ms()
                        local state = scope:state(name)
                        state.uses, state.lastUsed = (state.uses or latest.card.uses or 0)+1, now()
                        pcall(scope.save,scope,name,state)
                        local ran, value = pcall(self._execute,self,latest,args,scope,context,false)
                        state.lastMs = core.monotonic_ms()-started
                        state.slowestMs = math.max(state.slowestMs or 0,state.lastMs)
                        pcall(scope.save,scope,name,state)
                        if not view then
                            for _, field in ipairs({"uses", "lastUsed", "lastMs", "slowestMs"}) do latest.card[field]=state[field] end
                            pcall(scope.root.write,scope.root,"tools/" .. name .. "/tool.json",json.encode(latest.card) .. "\n")
                        end
                        if not ran then error(value,0) end
                        return value
                    end)
                    return ok and value or failure(value)
                end}
        else self.held[name] = why or "the tool awaits a review of these source bytes" end
    end
    -- The workflow supplies the selected, pinned skill definitions. Selection
    -- and fetched skill files belong to its task composition, not the shelf.
    for _, skill in ipairs(current(context).skills or {}) do
        for _, card in ipairs(skill.tools or {}) do
            if card.environment == "lua" then
                local sources, properties, required = json.array(), {}, json.array()
                for _, file in ipairs(card.files or {}) do sources[#sources+1]={name=file.name,text=file.content} end
                for _, param in ipairs(card.params or {}) do
                    properties[param.name]={type="string",description=param.description}
                    if param.required then required[#required+1]=param.name end
                end
                local spec={card=card,sources=sources,skill=skill.name}
                local native="skill." .. card.name
                tools[#tools+1]={name=native,description=(card.summary or "") .. " (skill " .. skill.name .. ")",
                    class=card.network and "external" or "exec",foreign=false,source=card.network and native or "",
                    group="workshop",program=digest(sources),parameters=schema(properties,required),
                    invoke=function(args)
                        local ok,value=pcall(self._execute,self,spec,args,scope,context,false)
                        return ok and value or failure(value)
                    end}
            else self.held["skill." .. card.name]="environment is unavailable in this Lua workshop" end
        end
    end
    return tools
end
function Workshop:close()
    for child in pairs(self.children) do child:close() end
    for _, root in pairs(self.roots) do root:close() end
    self.children, self.roots = {}, {}
end

return Workshop
