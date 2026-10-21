-- Approval decisions mirror loop/approvals.go and source.go. Returned events
-- are prepared, never sent here: persist them, append, then decide again with
-- context.event (the confirmed response) or context.error (the named refusal).
-- The caller refreshes the lease/cancellation state and runs its provenance,
-- address and mutator chain before this gate. No tool is invoked here.
local json = require("json")
local Authority = {}
Authority.__index = Authority
local outward = {external=true, physical=true}
local function object(v) return type(v) == "table" and v ~= json.null end
local function trim(v) return tostring(v or ""):match("^%s*(.-)%s*$") end
local function copy(v) local out = {}; for k, x in pairs(v or {}) do out[k] = x end; return out end

local function canonical(v)
    if not object(v) then return json.encode(v) end
    local parts, array = {}, (getmetatable(v) or {}).__jsontype == "array" or #v > 0
    if array then
        for i, x in ipairs(v) do parts[i] = canonical(x) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}; for k in pairs(v) do keys[#keys + 1] = k end; table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = json.encode(k) .. ":" .. canonical(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function payload(text)
    local ok, value = pcall(json.decode, text or "")
    if ok and object(value) and type(value.tool) == "string" and value.tool ~= "" and value.args ~= nil then return value end
end

-- The common authority.Within rule: exact names or a URL host/subdomain.
function Authority.within(thing, allowed)
    local folded = trim(thing):lower()
    for _, name in ipairs(allowed) do if folded == name then return true end end
    local host = folded:match("^[%a][%w+.-]*://([^/?#]+)") or folded:match("^//([^/?#]+)")
    if not host or host:find("[%s%%]") then return false end
    host = host:match(".*@(.+)$") or host
    if host:sub(1, 1) == "[" then host = host:match("^%[([^%]]+)%]:?%d*$")
    else host = host:match("^([^:]+):?%d*$") end
    if not host then return false end
    for _, name in ipairs(allowed) do
        if host == name or host:sub(-#name - 1) == "." .. name then return true end
    end
    return false
end

function Authority.new(client, task, history, registry, options)
    local Sequence = require("sequence")
    local self = setmetatable({client=client, task=task, registry=registry, options=options or {},
        history=Sequence.empty_like(history), byId={}, queued={}, blocked={}, byKey={}, foreign=false}, Authority)
    for _, event in ipairs(history or {}) do self:observe(event) end
    self.woke = self.options.woke or (#self.history > 0 and self.history[#self.history].eventId) or "begin"
    return self
end

function Authority:observe(event)
    if event.eventId and self.byId[event.eventId] then self.history[self.byId[event.eventId]] = event
    else
        self.history[#self.history + 1] = event
        if event.eventId then self.byId[event.eventId] = #self.history end
    end
    local tool = self.registry.byNative[event.title]
    local actor = self.options.actorId or self.task.assigneeId
    if event.outside or (event.kind == "attachment" and event.actorId ~= actor) or
        (event.kind == "message" and event.phase ~= "start" and event.errorCode ~= "mutator_refused" and tool and tool.foreign) then
        self.foreign = true
    end
end

function Authority:_tool(name)
    return self.registry:find(name) or self.registry.byNative[name]
end

function Authority:_state(approval, action)
    local state, tool = {}, action and self:_tool(action.tool)
    local native = tool and tool.name or action and action.tool
    for _, event in ipairs(self.history) do
        if event.causedBy == approval.eventId then
            if event.level == "trace" then
                if event.title == "carrying_out" then state.started = true
                elseif native and event.title == native then
                    if event.phase == "start" then state.started = true else state.done = true end
                end
            elseif event.kind == "question" then state.asked = true
            elseif event.kind == "message" or event.kind == "failure" then state.done = true end
        end
    end
    return state
end

-- Feed-order work before a model turn. Each item is a context for decide();
-- approval entries also carry the exact decoded call. Asked outcomes stay put.
function Authority:pending()
    local pending, attended, order, asked = {}, {}, {}, {}
    for _, event in ipairs(self.history) do
        if event.kind == "question" then asked[event.causedBy or ""] = true end
        if event.kind == "confirmation" and event.decision == "approved" then
            local action = payload(event.action)
            local state = self:_state(event, action)
            if not state.done and not (state.started and state.asked) then
                local tool = action and self:_tool(action.tool)
                pending[#pending + 1] = {approval=event, call=action and {id=event.eventId,
                    name=tool and tool.modelName or action.tool, args=action.args}}
            end
        end
        if event.level == "trace" and event.risk == "attended" then
            local key = (event.stepId or "") .. "\n" .. (event.title or "")
            if not attended[key] then attended[key] = {}; order[#order + 1] = key end
            if event.phase == "start" then attended[key][#attended[key] + 1] = event
            elseif #attended[key] > 0 then table.remove(attended[key], 1) end
        end
    end
    for _, key in ipairs(order) do
        for _, start in ipairs(attended[key]) do
            if not asked[start.eventId] then pending[#pending + 1] = {start=start} end
        end
    end
    return pending
end

function Authority:_event(status, reason, event)
    return {status=status, reason=reason, event=self.client:prepare(event)}
end

function Authority:_unknown(cause, native, context)
    if context.event and context.event.kind == "question" then
        return {status="defer", reason="unknown_action_outcome"}
    end
    return self:_event("defer", "unknown_action_outcome", {kind="question", title="question",
        body="The action " .. native .. " started earlier; its outcome was not recorded. Did it happen?",
        options=json.array({{label="It happened", hint="Continue with the result treated as done."},
            {label="It did not happen", hint="The assistant may propose the action again."}}),
        addresseeIds=json.array({self.task.ownerId}), state="input_required",
        causedBy=cause, requestId=cause .. "/unknown"})
end

function Authority:_carry(call, context)
    local approval, event = context.approval, context.event
    local action = payload(approval.action)
    local tool = action and self:_tool(action.tool)
    local native = tool and tool.name or action and action.tool or approval.title
    local state = self:_state(approval, action)
    if state.done then return {status="refused", reason="already_carried"} end
    if event and event.kind == "question" then return {status="defer", reason="unknown_action_outcome"} end
    local reason = object(context.error) and context.error.reason
    if reason == "approval_opened" or (state.started and not (event and event.title == "carrying_out")) then
        if state.asked then return {status="defer", reason="unknown_action_outcome"} end
        return self:_unknown(approval.eventId, native, context)
    end
    local invalid = not action or not tool or reason == "approval_lapsed" or reason == "outside_authority"
    if invalid then
        local why = reason or (action and "approved_tool_unavailable" or "unreadable_approval")
        return self:_event("refused", why, {kind=reason and "message" or "failure", title=native,
            body="The approved action was not carried out: " .. why .. ".", errorCode=reason,
            errorDetail=context.error and tostring(context.error.message), causedBy=approval.eventId,
            requestId=approval.eventId .. "/carried"})
    end
    if context.error then error(context.error, 0) end
    if approval.decision ~= "approved" then return {status="refused", reason="approval_not_approved"} end
    if not call or self:_tool(call.name) ~= tool or canonical(call.args or {}) ~= canonical(action.args or {}) then
        return {status="refused", reason="approved_action_mismatch"}
    end
    if event and event.title == "carrying_out" and event.causedBy == approval.eventId then
        return {status="execute", approvedAction=approval.action, causedBy=approval.eventId}
    end
    return self:_event("defer", "open_approval", {kind="message", level="trace", title="carrying_out",
        body="Carrying out the approved " .. native .. ".", action=approval.action, causedBy=approval.eventId,
        requestId=approval.eventId .. "/carrying@" .. self.woke})
end

function Authority:_verdict(event, call, entry)
    local key = call.name .. "\n" .. canonical(call.args or {})
    if event.guard == "pass" then
        local action = payload(event.action or entry.action)
        if not action or action.tool ~= call.name or canonical(action.args or {}) ~= canonical(call.args or {}) then
            return {status="refused", reason="approved_action_mismatch"}
        end
        return {status="execute", approvedAction=event.action or entry.action, causedBy=event.eventId}
    end
    if event.guard == "block" or event.guard == "hard_deny" then
        local blocked = {status="refused", reason=event.guardReason or event.guard, hard=event.guard == "hard_deny"}
        if not blocked.hard then blocked.blockedId = event.eventId end
        self.blocked[event.eventId] = {entry=entry, result=blocked, key=key}
        self.byKey[key] = blocked
        return blocked
    end
    if event.decision == "denied" and (not event.guard or event.guard == "") then
        return {status="refused", reason="approval_denied"}
    end
    self.queued[key] = true
    return {status="defer", reason="approval_pending", causedBy=event.eventId}
end

function Authority:decide(call, context)
    context = context or {}
    if context.foreign then self.foreign = true end
    if context.event then self:observe(context.event) end
    if context.start then return self:_unknown(context.start.eventId, context.start.title, context) end
    if context.approval then return self:_carry(call, context) end
    if context.error then error(context.error, 0) end
    local tool = self.registry:find(call.name)
    if call.error or not tool then return {status="execute"} end -- Registry returns the model error.
    local bound, source = context.readBound or self.client.readBound or {}, trim(tool.source)
    if #bound > 0 and source ~= "" and not (outward[tool.class] and not tool.foreign) and
        not Authority.within(source, bound) then
        local urls = object(call.args) and call.args.url
        if type(urls) == "string" then urls = {urls} end
        local found, outside = false, false
        for _, url in ipairs(object(urls) and urls or {}) do
            if type(url) == "string" and trim(url) ~= "" then
                found, outside = true, outside or not Authority.within(url, bound)
            end
        end
        if not found or outside then return {status="refused", reason="outside_read_bound"} end
    end
    if tool.class == "attended" and context.taskState == "canceled" then
        return {status="refused", reason="canceled"}
    end
    if not outward[tool.class] then return {status="execute"} end
    local key = call.name .. "\n" .. canonical(call.args or {})
    if self.queued[key] then return {status="defer", reason="approval_pending"} end
    if self.byKey[key] then return self.byKey[key] end
    local action = {tool=call.name, args=call.args or {}}
    if self.foreign then action.foreignText = true end
    if context.via and context.via ~= "" then action.via = context.via end
    local entry = {kind="confirmation", title=tool.name, risk=tool.class,
        body="The assistant wants to run this " .. tool.class .. " action.",
        quoted=(tool.name .. " " .. (call.arguments or json.encode(action.args))):sub(1, 2000),
        action=json.encode(action), addresseeIds=json.array({self.task.ownerId}),
        causedBy=context.causedBy, stepId=context.stepId,
        requestId=assert(context.stepId, "action requires stepId") .. "/" .. assert(call.id, "action requires call id") .. "/queue"}
    if context.event then
        assert(context.event.kind == "confirmation", "approval continuation requires a confirmation")
        entry.action = context.event.action or entry.action
        return self:_verdict(context.event, call, entry)
    end
    return self:_event("defer", "queue_approval", entry)
end

-- Explicit model-requested escalation keeps the blocked payload byte for byte.
-- Hard denials never expose an escalation id and never produce an event here.
function Authority:escalate(id, why, context)
    context = context or {}
    local blocked = self.blocked[id]
    if not blocked or blocked.result.hard then return {status="refused", reason="action_not_escalatable"} end
    if blocked.escalated then return {status="defer", reason="approval_pending"} end
    if trim(why) == "" then return {status="refused", reason="escalation_requires_reason"} end
    if context.event then
        self:observe(context.event)
        blocked.escalated, self.queued[blocked.key] = true, true
        return {status="defer", reason="approval_pending", causedBy=context.event.eventId}
    end
    if context.error then error(context.error, 0) end
    local entry = copy(blocked.entry)
    entry.body, entry.escalate, entry.causedBy = trim(why):sub(1, 600), true, id
    entry.stepId = assert(context.stepId, "escalation requires stepId")
    entry.requestId = entry.stepId .. "/" .. assert(context.callId, "escalation requires callId") .. "/escalate"
    return self:_event("defer", "escalate_approval", entry)
end

return Authority
