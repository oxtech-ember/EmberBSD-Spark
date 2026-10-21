-- Small built-ins use the same server contracts as agent/internal/toolset.
-- The caller supplies a task-scoped client and trusted per-call provenance;
-- execution authority, readBound and tracing remain the workflow's concern.
local json = require("json")
local Client = require("client")
local M = {}
local function map(value) return setmetatable(value or {}, {__jsontype="object"}) end
local function trim(value) return (value or ""):match("^%s*(.-)%s*$") end
local function copy(value)
    local out = map()
    for key, item in pairs(value or {}) do out[key] = item end
    return out
end
local function text(value) return {type="string", description=value} end
local function enum(values) return {type="string", enum=json.array(values)} end
local function array(items) return {type="array", items=items} end
local function schema(properties, required)
    return {type="object", properties=map(properties), required=json.array(required), additionalProperties=false}
end
local function answer(value, message, given)
    return {content=json.array({{type="text", text=message or json.encode(value)}}),
        structuredContent=value, given=given}
end
local function failure(reason)
    local detail = type(reason) == "table" and reason or {}
    local message = detail.message or detail.error or detail.reason or tostring(reason)
    if type(message) ~= "string" then message = json.encode(message) end
    return {isError=true, content=json.array({{type="text", text=message}}),
        structuredContent={error=message, reason=detail.reason, status=detail.status, response=detail.body}}
end
local function integer(value, default)
    if value == nil then return default end
    assert(type(value) == "number" and value % 1 == 0, "expected an integer")
    return value
end
local function days(value)
    value = integer(value, 7)
    return value <= 0 and 7 or value
end
local function required(value, name)
    assert(type(value) == "string" and trim(value) ~= "", name .. " is required")
    return value
end
local function given(event)
    if not event or (event.actorIsAgent and not event.outside) then return "" end
    return (event.body or "") .. "\n"
end
local function skillPath(name)
    name = trim(name):lower()
    assert(#name <= 40 and name:match("^[a-z][a-z0-9-]*$"), "invalid skill name")
    return "skills/" .. name .. "/skill.json", name
end
local function published(view, path)
    return view:published(path) or ""
end
local function readDraft(view, path)
    for _, name in ipairs(view:list()) do if name == path then return view:read(path) end end
end
local function waiting(candidate)
    return candidate and (candidate.state == "pending" or candidate.state == "running")
end

-- Stable request IDs survive a restarted Lua process with a different hash seed.
local function canonical(value)
    if type(value) ~= "table" or value == json.null then return json.encode(value) end
    local parts = {}
    if #value > 0 or (getmetatable(value) or {}).__jsontype == "array" then
        for _, item in ipairs(value) do parts[#parts + 1] = canonical(item) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do parts[#parts + 1] = json.encode(key) .. ":" .. canonical(value[key]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

local evidence = array(schema({eventId=text("Record identifier"), note=text("What this record establishes")}, {"eventId", "note"}))
local investigationSchema = schema({
    action=enum({"read", "update", "share"}),
    state=schema({previous=text("Latest investigation event ID; empty for the first revision"), question=text("Question"),
        hypotheses=array(schema({id=text("Identifier"), claim=text("Claim"), status=enum({"open", "supported", "refuted"}),
            supports=evidence, against=evidence}, {"id", "claim", "status"})),
        checks=array(schema({id=text("Identifier"), action=text("Check"), hypotheses=array(text("Hypothesis ID")),
            expected=text("Expected result"), time=text("Time"), cost=text("Cost"), permission=text("Permission"),
            status=enum({"planned", "done", "unavailable"}), results=evidence}, {"id", "action", "hypotheses", "expected", "status"})),
        nextCheck=text("Next check"), conclusion=text("Conclusion"),
        outcome=schema({status=enum({"unknown", "succeeded", "partial", "failed"}), summary=text("Summary"), evidence=evidence}, {"status"})},
        {"previous", "question", "hypotheses", "checks", "outcome"}),
    investigationId=text("Investigation event to share"), conditions=text("Applicable conditions"),
    lesson=text("Reusable lesson"), message=text("Publication message")}, {"action"})

function M.tools(client, task, options)
    options, task = options or {}, task or {}
    local config, view = options.config or client.config or {}, options.worktree
    local taskId = task.taskId or task.id or ""
    local ownerId = trim(task.ownerId)
    local materialId = options.materialTask or task.materials or taskId
    local result = json.array()
    local function request(method, path, body) return client:request(method, path, body) end
    local function taskPath(material)
        return "/api/v1/tasks/" .. Client.escape(required(material and materialId or taskId, "task"))
    end
    local function context()
        local value = type(options.context) == "function" and options.context() or options.context or {}
        return value
    end
    local function provenance(withAuthor)
        local value = context()
        assert(value.origin == "agent" or value.origin == "external", "the workflow must supply provenance")
        local author = value.author or {}
        if withAuthor then
            assert(trim(author.alias) ~= "" or trim(author.model) ~= "", "the workflow must supply a known author")
        end
        return value.origin, {alias=author.alias or "", model=author.model or ""}
    end
    local function stage(path, body)
        required(taskId, "task")
        local origin, author = provenance(true)
        view:set_provenance(author, origin)
        view:write(path, body)
        return answer({path=path, state="draft", revision=view.revision}, "Staged in the task draft; publish the worktree to propose this change.")
    end
    local function add(name, class, description, parameters, traits, invoke)
        local descriptor = copy(traits)
        descriptor.name, descriptor.class, descriptor.description = name, class, description
        descriptor.parameters, descriptor.foreign = parameters, descriptor.foreign == true
        descriptor.group, descriptor.source = "oxtorg-native", ""
        descriptor.invoke = function(args)
            local ok, value = pcall(invoke, args or {})
            return ok and value or failure(value)
        end
        result[#result + 1] = descriptor
    end

    add("my_failures", "read", "Read your recent refusals, grouped by shape, with the standing layer and its version. Read before teach_myself; fix: tool calls for a tool change.",
        schema({days={type="integer"}}), {bringsNothingIn=true, echoes=true}, function(args)
            local path = "/api/v1/me/failures?days=" .. days(args.days)
            if view then path = path .. "&revision=" .. Client.escape(view.revision) end
            local value = request("GET", path)
            if view then
                value.layer, value.publishedLayer = readDraft(view, "role/agent.md") or "", published(view, "role/agent.md")
                value.layerDraft, value.worktreeRevision = true, view.revision
            end
            return answer(value, nil, "")
        end)
    add("teach_myself", "write_local", "Replace your entire learned role layer. Read my_failures first; keep valid lessons and name the evidence. The server reviews a proposal before it acts.",
        schema({layer=text("The complete replacement layer"), basis=text("Evidence from your refusals")}), {provenance="whole"}, function(args)
            required(args.basis, "basis")
            local origin, author = provenance(true)
            if view then return stage("role/agent.md", args.layer or "") end
            local value = request("PUT", "/api/v1/me/role/layer", {layer=args.layer or "", basis=args.basis,
                origin=origin, author=author, taskId=taskId})
            return answer(value, waiting(value.candidate) and "The new layer awaits review; the returned role still stands." or "The candidate was not accepted for review; the returned role still stands.")
        end)
    add("set_my_ceiling", "write_local", "Set one of your own limits from refusal evidence; zero restores the installation value. Changes apply from the next task.",
        schema({variable=enum({"turns", "continuations", "compaction"}), value={type="integer"}, basis=text("Evidence for this change")},
            {"variable", "value", "basis"}), {provenance="whole"}, function(args)
            required(args.basis, "basis")
            local value = integer(args.value)
            assert(value ~= nil, "value is required")
            assert(args.variable == "turns" or args.variable == "continuations" or args.variable == "compaction", "unknown ceiling variable")
            assert(args.variable ~= "compaction" or value == 0 or options.compacts, "this installation has no compactor")
            local origin = provenance(false)
            return answer(request("PUT", "/api/v1/me/ceiling", {variable=args.variable, value=value, basis=args.basis, origin=origin}))
        end)
    add("investigation", "write_local", "Read or update this task's hypotheses, evidence, checks and conclusion. Share requires the corporate case publication adapter.",
        investigationSchema, {bringsNothingIn=true, kept=true, provenance="whole"}, function(args)
            required(taskId, "task")
            if args.action == "share" then
                assert(options.shareInvestigation, "sharing an investigation requires the corporate case publication adapter")
                local origin, author = provenance(true)
                local input = copy(args)
                input.origin, input.author = origin, author
                return options.shareInvestigation(input, task)
            elseif args.action == "update" then
                assert(type(args.state) == "table" and args.state ~= json.null, "state is required")
                local state = copy(args.state)
                state.hypotheses, state.checks = json.array(copy(state.hypotheses)), json.array(copy(state.checks))
                local key = "investigation-" .. require("asenta.fs").sha256(taskId .. "\0" .. canonical(state))
                local event = client:append{kind="message", title="Investigation",
                    body=(state.question or "") .. "\n" .. (state.conclusion or ""), investigation=state, requestId=key}
                return answer({eventId=event.eventId, state=event.investigation or json.null})
            end
            assert(args.action == "read", "action must be read, update or share")
            local history, event, sources = client:history(), {}, json.array()
            for _, item in ipairs(history) do if item.investigation then event = item end end
            for i = #history, 1, -1 do
                local item = history[i]
                if #sources < 16 and not item.investigation and (item.body or "") ~= "" and
                    (item.recalledAt or "") == "" and not (item.level == "trace" and (item.phase or "") ~= "") then
                    local stop = utf8.offset(item.body, 301)
                    sources[#sources + 1] = {eventId=item.eventId, actor=item.actor, at=item.at, title=item.title,
                        extract=stop and item.body:sub(1, stop - 1) or item.body}
                end
            end
            return answer({eventId=event.eventId or "", state=event.investigation or json.null, sources=sources})
        end)
    add("who_helped_me", "read", "Read who helped this task's owner this week and the remaining bonus fund. Marking helpers remains the person's decision.",
        schema(), {}, function()
            local query = "?subjectId=" .. Client.escape(required(ownerId, "task owner"))
            local helpers = request("GET", "/api/v1/market/helpers" .. query)
            local ok, fund = pcall(request, "GET", "/api/v1/market/fund" .. query)
            if not ok and (type(fund) ~= "table" or fund.reason ~= "market_off") then error(fund, 0) end
            return answer({helpers=helpers.helpers or json.array(), fund=ok and fund or json.null, marketOff=not ok})
        end)
    add("org_outcomes", "read", "Read the organisation's work outcomes and costs in units over the last days; default seven, maximum ninety.",
        schema({days={type="integer"}}), {}, function(args)
            local count = days(args.days)
            assert(count <= 90, "at most 90 days may be counted")
            return answer(request("GET", "/api/v1/org/outcomes?days=" .. count))
        end)
    add("read_skill", "read", "Read a skill's installed text and agent layer separately, with its last ten versions, before write_skill.",
        schema({name=text("Skill name")}, {"name"}), {bringsNothingIn=true, kept=true}, function(args)
            local name = trim(args.name):lower()
            if view then
                local path = skillPath(name)
                local raw = readDraft(view, path)
                local source = raw and json.decode(raw) or map()
                local installed
                for _, skill in ipairs(options.installedSkills or {}) do if skill.name == name then installed = skill end end
                assert(raw or installed, "no skill named " .. name)
                assert(not raw or source.name == name, "skill source name differs from its path")
                return answer({layer={name=name, summary=source.summary or "", text=source.text or "", version=source.version,
                    installedSummary=installed and installed.summary, installedText=installed and installed.text}, source=source, revision=view.revision})
            end
            local ok, value = pcall(request, "GET", "/api/v1/skills/" .. Client.escape(name) .. "/versions")
            if not ok then
                if type(value) ~= "table" or value.status ~= 404 then error(value, 0) end
                local found, catalogue = pcall(request, "GET", "/api/v1/skills")
                local names = {}
                for _, skill in ipairs(found and catalogue.skills or {}) do names[#names + 1] = skill.name end
                error("no skill named " .. name .. "; available: " .. table.concat(names, ", "), 0)
            end
            local versions = json.array()
            for i = 1, math.min(10, #(value.versions or {})) do versions[i] = value.versions[i] end
            return answer({layer=value.layer, versions=versions})
        end)
    add("write_skill", "write_local", "Replace your skill layer or create a skill. The installation's text stays separate. A server proposal waits for review.",
        schema({name=text("Lowercase skill name"), summary=text("Short summary"), text=text("Entire agent layer"), basis=text("Evidence")}, {"name", "basis"}),
        {bringsNothingIn=true, provenance="whole"}, function(args)
            required(taskId, "task"); required(args.basis, "basis")
            local origin, author = provenance(true)
            local name = trim(args.name):lower()
            if view then
                local path = skillPath(name)
                local raw = readDraft(view, path)
                local source = raw and json.decode(raw) or {name=name}
                assert(source.name == name, "skill source name differs from its path")
                source.summary, source.text = args.summary or "", args.text or ""
                local remove = trim(source.summary) == "" and trim(source.text) == "" and #(source.files or {}) == 0 and #(source.tools or {}) == 0
                if remove and not raw then return answer({path=path, state="absent"}) end
                return stage(path, not remove and json.encode(source) or nil)
            end
            local value = request("PUT", "/api/v1/skills/" .. Client.escape(name) .. "/layer", {summary=args.summary or "", text=args.text or "",
                basis=args.basis, origin=origin, taskId=taskId, fresh=false, author=author})
            return answer(value, waiting(value.candidate) and "The skill proposal awaits review; the returned layer still stands." or "The skill proposal was not accepted for review.")
        end)
    add("search_history", "read", "Find past matters by words. Extracts are shortened; read_original retrieves a record whole. The server uses the task as the access boundary.",
        schema({query=text("At least three characters"), limit={type="integer"}}, {"query"}), {foreign=true, echoes=true}, function(args)
            local query = required(args.query, "query")
            assert((utf8.len(trim(query)) or 0) >= 3, "query needs at least three characters")
            local limit = integer(args.limit, 5)
            if limit <= 0 then limit = 5 end
            local value = request("GET", taskPath(true) .. "/search?limit=" .. limit .. "&q=" .. Client.escape(query))
            local parts = {}
            for _, hit in ipairs(value.hits or {}) do
                parts[#parts + 1] = given(hit.event)
                for _, group in ipairs({hit.ends or {}, hit.before or {}, hit.after or {}}) do
                    for _, event in ipairs(group) do parts[#parts + 1] = given(event) end
                end
            end
            return answer(value, nil, table.concat(parts))
        end)
    add("read_original", "read", "Read a past feed record whole by its event ID, including the recorded call or citation. Access is anchored to this task.",
        schema({eventId=text("Record identifier")}, {"eventId"}), {foreign=true, echoes=true, readsRecords=true}, function(args)
            local eventId = trim(required(args.eventId, "eventId"))
            local value = request("GET", taskPath(true) .. "/events/" .. Client.escape(eventId))
            return answer(value, nil, given(value.event))
        end)
    if (config.model or {}).memory then
        add("remember", "write_local", "Remember a concise fact about this task's owner or the organisation. The response states whether it acts or awaits a person's acceptance.",
            schema({scope=enum({"person", "org"}), key=text("Fact key"), text=text("Fact"), origin=enum({"agent", "external"})}, {"scope", "key", "text"}),
            {bringsNothingIn=true, provenance="quarantine"}, function(args)
                assert(args.scope == "person" or args.scope == "org", "scope must be person or org")
                local path = "/api/v1/facts"
                if args.scope == "person" then path = path .. "?subjectId=" .. Client.escape(required(ownerId, "task owner")) end
                local origin = context().origin == "external" and "external" or args.origin
                assert(origin == nil or origin == "agent" or origin == "external", "origin must be agent or external")
                local value = request("PUT", path, {scope=args.scope, key=args.key or "", text=args.text or "", origin=origin})
                return answer(value, value.state == "pending" and "Proposed; it does not act until a person accepts it." or "Remembered.")
            end)
    end
    return result
end

return M
