-- Pure plans for loop/{gatewaylimit,outcomes,keys}. The caller persists the
-- plan, appends its event, then applies wake. No clock, transport or model IO.
local secrets = require("secrets")
local Failures = {maxAttempts=3}
local function nonempty(value) return type(value) == "string" and value ~= "" end
local function id(event) return event and (event.eventId or event.id) or "" end
local function said(err)
    local value = err
    if type(err) == "table" then
        value = err.message or err.error
        if type(value) == "table" then value=value.message end
        value = value or err.reason or "The attempt failed"
    end
    return secrets.text(tostring(value or "The attempt failed"))
end
local function head(value, limit)
    if #value <= limit then return value end
    while limit > 0 and value:byte(limit+1) >= 128 and value:byte(limit+1) < 192 do limit=limit-1 end
    return value:sub(1,limit)
end

-- Opening a turn/call/attempt is not progress. Only a completed event resets
-- the consecutive failure count and supplies the next series' request key.
function Failures.series(history)
    local count = 0
    for index=#history,1,-1 do
        local event=history[index]
        if event.phase ~= "start" and event.title ~= "attempt_entered" and event.title ~= "conditions_read" then
            if event.kind ~= "failure" or event.title ~= "failed" then return id(event),count end
            count=count+1
        end
    end
    return "",count
end

local function quiet(task, err)
    local reason=type(err) == "table" and err.reason or nil
    if task.state == "canceled" or reason == "task_canceled" or reason == "canceled" or reason == "cancelled" then
        return "canceled"
    end
    if reason == "changed_meanwhile" or reason == "stale" then return "stale" end
    if reason == "lease_taken" or reason == "lease_lost" then return "lease_lost" end
    if reason == "asleep" then return "deferred" end
end
local function limited(err, ctx)
    if type(err) ~= "table" then return false end
    if err.reason == "gateway_limit" then return true end
    -- An HTTP status from a server/tool is not a model refusal. Ordinary 429
    -- bursts also do not mean that a daily/account limit was exhausted.
    if nonempty(err.reason) or not (err.gateway == true or ctx.gateway == true) then return false end
    return err.status == 402 or said(err):lower():find("day token limit",1,true) ~= nil
end

-- ctx carries the persisted attempt identity and answered model. A stale task
-- is read by the caller before planning with its fresh state; no event is
-- written to revive a canceled task or to compete with another lease holder.
function Failures.plan(history, task, err, context)
    history,context=history or {},context or {}
    assert(type(task) == "table" and nonempty(task.taskId or task.id), "a task is required for a failure plan")
    local taskId, outcome=task.taskId or task.id,quiet(task,err)
    if outcome then return {outcome=outcome} end
    local reason=type(err) == "table" and err.reason or nil
    local detail=said(err)
    if reason == "mutator_broken" then
        local woke=context.woke or id(history[#history])
        return {code="mutator_broken",outcome="mutator_broken",gaveUp=true,event={
            kind="failure",title="mutator_broken",state="failed",errorCode="mutator_broken",
            errorDetail=head(detail,500),body=detail .. ". The assistant stopped because an accepted mutator could not run.",
            causedBy=context.causedBy,requestId=taskId .. "/" .. (woke ~= "" and woke .. "/" or "") .. "mutator-broken"}}
    end
    if not context.wakeFailed and limited(err,context) then
        assert(nonempty(context.stepId), "a persisted step ID is required for a gateway refusal")
        return {code="gateway_limit",outcome="deferred",gaveUp=false,event={
            kind="message",level="trace",title="gateway_limit",errorCode="gateway_limit",
            modelAlias=context.modelAlias,model=context.model,errorDetail=detail,
            body="The gateway refused the turn over its limit: " .. detail,
            requestId=taskId .. "/" .. context.stepId .. "/gateway-limit"},
            wake={afterSeconds=1800,note="The work waits for the gateway's limit to lift."}}
    end
    local opened,count=Failures.series(history)
    local attempt=count+1
    local gaveUp=attempt >= Failures.maxAttempts
    local event={kind="failure",title="failed",level=not gaveUp and "trace" or nil,
        state=gaveUp and "failed" or nil,modelAlias=context.modelAlias,model=context.model,
        errorCode="runner",errorDetail=detail,
        requestId=taskId .. "/fail/" .. (opened ~= "" and opened .. "/" or "") .. attempt,
        body=gaveUp and "The work failed after 3 attempts: " .. detail or
            "Attempt " .. attempt .. " of 3 failed: " .. detail .. ". The work will be tried again."}
    return {event=event,code="runner",attempt=attempt,gaveUp=gaveUp,outcome=gaveUp and "failed" or nil}
end
return Failures
