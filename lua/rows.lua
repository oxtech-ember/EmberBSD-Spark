-- Small-profile runs: independent rows, one paid request per row, no tools.
-- Runtime persists each paid request and its returned usage before delivery.
-- The server's identical row PUT is idempotent, including after run closure.
-- Charges precede that PUT: closing the last row must not strand its charge.
-- A definite seat refusal leaves the row pending for a later sweep; an unknown
-- paid outcome records spendUnknown and fails the run without repeating it.
local json = require("json")
local core = require("asenta.core")
local Runtime = require("runtime")
local secrets = require("secrets")
local Rows = {}
local prompt = "You are given one subject and a general question about it. Answer briefly in one or two sentences. Your answer will be one row beside many others, read down a column. Do not retell the question or explain your reasoning. If there is nothing to answer about the subject, say so in one sentence."
local function copy(value) local out={};for k,v in pairs(value or {}) do out[k]=v end;return out end
local function trim(value) return type(value)=="string" and value:match("^%s*(.-)%s*$") or "" end
local function escape(value) return value:gsub("[^%w%-._~]",function(c)return ("%%%02X"):format(c:byte()) end) end
local function message(err) return type(err)=="table" and (err.message or err.reason or "Model request failed") or tostring(err) end

-- Match llm.AboutTheSeat: only request-specific 400/413/422 refusals belong
-- to one row. A gateway's named breakdown and our server's reason do not.
local function rowRefusal(err)
    if err.reason=="model_incomplete" then return true end
    if trim(err.reason)~="" then return false end
    if err.status~=400 and err.status~=413 and err.status~=422 then return false end
    local said=message(err):lower()
    for _,part in ipairs({"safety guard unavailable","rate limit exceeded for /","circuit breaker is open","request blocked by safety policy","day token limit"}) do
        if said:find(part,1,true) then return false end
    end
    return true
end
local function gatewayLimit(err)
    return err and trim(err.reason)=="" and (err.status==402 or message(err):lower():find("day token limit",1,true)~=nil)
end

function Rows.run(ctx)
    local client,model=ctx.client,ctx.model
    local path="/api/v1/tasks/" .. escape(ctx.task.taskId)
    local handlers,runtime={},nil
    function handlers.checkpoint() return {client={version=client.version,readUpTo=client.readUpTo}} end
    function handlers.read() return client:request("GET",path .. "/items") end
    function handlers.lease() return client:lease(ctx.task.taskId) end
    function handlers.append(entry) return client:append(entry) end
    function handlers.fill(input)
        return client:request("PUT",path .. "/items/" .. escape(input.itemId),input.value)
    end
    function handlers.wake(input)
        local reply=client:request("POST",path .. "/wake",input)
        client.version=assert(reply.task.version,"wake response requires task version")
        return reply
    end
    function handlers.model(input)
        local started=core.monotonic_ms()
        local ok,reply=pcall(model.request,model,input.messages,json.array(),input.task)
        if not ok then
            local err=type(reply)=="table" and reply or {message=tostring(reply)}
            -- No acknowledged refusal or parsed paid reply: Runtime must retain
            -- the uncertain model effect rather than retrying it next sweep.
            if not err.usage and (not err.status or err.status<400) then error(err,0) end
            reply={error={message=message(err),reason=err.reason,status=err.status},
                usage=err.usage or {units=0,cachedUnits=0,chargedUnits=0,costMicro=0,spendUnknown=false},
                modelAlias=err.modelAlias,model=err.model}
        end
        reply.durationMs=core.monotonic_ms()-started
        return secrets.value(reply)
    end
    runtime=Runtime.open(ctx.root,ctx.stateName,{taskId=ctx.task.taskId,attemptId=core.identifier(),data={
        task={taskId=ctx.task.taskId,title=ctx.task.title,subtitle=ctx.task.subtitle,seat=ctx.task.seat},
        role=ctx.role,roleVersion=ctx.roleVersion,revision=ctx.revision,index=1,filled=0,
        client={version=client.version,readUpTo=client.readUpTo}}},handlers)
    local saved=runtime.state.data.client
    if saved then client.version,client.readUpTo=saved.version,saved.readUpTo end
    local yielded=false
    local function advance(phase,changes) runtime:advance(phase,changes) end
    local function append(entry,next,changes)
        runtime:issue({kind="append",input=client:prepare(entry),next=next},changes)
    end
    local phases={}
    function phases.prepare()
        runtime:issue({kind="read",input={},next="listed"})
    end
    function phases.listed()
        local waiting=json.array()
        for _,item in ipairs(assert(runtime.state.last.value.items,"run response requires items")) do
            if item.state=="pending" then waiting[#waiting+1]=item end
        end
        if #waiting==0 then runtime:finish("no_pending_rows")
        else advance("row_ready",{items=waiting}) end
    end
    function phases.row_ready(d)
        if d.index>#d.items then runtime:finish("rows_filled");return end
        runtime:issue({kind="lease",input={},next="row_request"})
    end
    function phases.row_request(d)
        local subject=trim(d.task.title)
        if trim(d.task.subtitle)~="" then subject=subject .. "\n" .. trim(d.task.subtitle) end
        local messages=json.array({{role="system",content=d.role or ""},{role="system",content=prompt},
            {role="user",content=subject .. "\n\nSubject: " .. d.items[d.index].input}})
        -- The installed before-turn mutators see every row as turn one. Their
        -- transformed messages are persisted in the effect before paid IO.
        if ctx.beforeTurn then messages=assert(ctx.beforeTurn(messages,1,d),"beforeTurn returned no messages") end
        runtime:issue({kind="model",input={messages=messages,task=d.task},next="row_answered"},
            {modelRequestId=runtime.state.attemptId .. "/" .. (runtime.state.seq+1),error=json.null})
    end
    function phases.row_answered(d)
        local reply=runtime.state.last.value
        local entry=copy(reply.usage)
        entry.kind,entry.level,entry.title="message","trace","thinking"
        entry.modelAlias,entry.model,entry.durationMs=reply.modelAlias,reply.model,reply.durationMs
        entry.requestId=d.modelRequestId .. "/usage"
        append(entry,"row_recorded",{reply=reply})
    end
    function phases.row_recorded(d)
        local reply=d.reply
        if reply.error and not rowRefusal(reply.error) then
            if gatewayLimit(reply.error) then
                append({kind="message",level="trace",title="gateway_limit",errorCode="gateway_limit",
                    errorDetail=message(reply.error),body="The gateway refused over its limit: " .. message(reply.error),
                    modelAlias=reply.modelAlias,model=reply.model,requestId=d.modelRequestId .. "/limit"},
                    "gateway_wait",{error=reply.error})
            else
                -- Keep an active durable continuation so the scheduler may
                -- retry a definitive seat refusal without discarding this run.
                advance("row_ready",{error=reply.error});yielded=true
            end
            return
        end
        local answer,reason=trim(reply.answer),reply.error and message(reply.error) or ""
        if reason~="" then answer=""
        elseif answer=="" then reason="The model returned an empty answer." end
        runtime:issue({kind="fill",replay="delivery",input={itemId=d.items[d.index].itemId,
            value={answer=answer,error=reason}},next="row_filled"})
    end
    function phases.row_filled(d)
        advance("row_ready",{index=d.index+1,filled=d.filled+1,reply=json.null})
    end
    function phases.gateway_wait()
        -- Re-delivery may extend the wait after a lost acknowledgement; it
        -- cannot re-run a paid request or change a row's answer.
        runtime:issue({kind="wake",replay="safe",input={afterSeconds=1800,
            note="The work waits for the gateway: its limit is spent. Continue when access returns."},next="gateway_waiting"})
    end
    function phases.gateway_waiting()
        advance("row_ready");yielded=true
    end
    function phases.uncertain(d)
        append({kind="failure",title="failed",errorCode="model_outcome_unknown",state="failed",spendUnknown=true,
            body="The model request for row " .. d.items[d.index].itemId .. " was interrupted. Its result and charge could not be recovered; the paid request was not repeated.",
            requestId=d.modelRequestId .. "/unknown"},"uncertain_recorded")
    end
    function phases.uncertain_recorded() runtime:finish("model_outcome_unknown") end

    local ok,why=pcall(function()
        if runtime.state.mode=="waiting" or runtime.state.mode=="parked" then runtime:resume() end
        while not yielded do
            if runtime.state.mode=="parked" and runtime.state.certainty~="not_started" and
                runtime.state.pending and runtime.state.pending.kind=="model" then
                runtime:recover("uncertain",{modelRequestId=runtime.state.pending.id})
            end
            if runtime.state.mode~="active" then break end
            local phase=runtime.state.phase
            if ctx.historyChanged and (phase=="prepare" or phase=="listed" or phase=="row_ready" or phase=="row_request") then
                runtime:finish("superseded");break
            end
            assert(phases[phase],"unknown rows phase: " .. tostring(phase))(runtime.state.data)
        end
    end)
    local state=runtime.state
    runtime:close()
    if not ok then error(why,0) end
    local err=state.data.error~=json.null and state.data.error or nil
    return {outcome=yielded and (gatewayLimit(err) and "gateway_limit" or "model_failed") or state.outcome or state.mode,
        filled=state.data.filled,error=err,reason=err and message(err) or state.reason,version=client.version,
        revision=state.data.revision,resume=yielded or state.outcome=="superseded" or
            (state.mode=="waiting" and state.certainty~="not_started" and state.pending and state.pending.replay~="never") or false}
end

return Rows
