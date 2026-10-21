-- The application workflow composes adapters around the durable attempt.
-- Every phase selects one effect; concrete tool names never become phases.
local json = require("json")
local fs = require("asenta.fs")
local core = require("asenta.core")
local Runtime = require("runtime")
local Sequence = require("sequence")
local Context = require("context")
local Controls = require("controls")
local Documents = require("documents")
local Failures = require("failures")
local secrets = require("secrets")
local Runner = {}
local function copy(value)
    local out = {}; for k,v in pairs(value or {}) do out[k]=v end; return out
end
local function eventID(event) return event and (event.eventId or event.id) end
local function block(text)
    return text and text ~= "" and {runes=utf8.len(text),digest=fs.sha256(text)} or {runes=0}
end
local function serializable(value)
    local ok = pcall(json.encode,value)
    return ok and value or nil
end

function Runner.run(ctx)
    local client, registry, model = ctx.client, ctx.registry, ctx.model
    local authority = ctx.authority
    local function definitionsFor(state)
        local result,folded=registry:definitions(ctx.controls and ((state or {}).described or {}) or nil)
        if ctx.controls then
            local c=copy(ctx.controlContext);c.task=ctx.task;c.history=ctx.history;c.state=state
            c.registry,c.folded=registry,folded
            for _,definition in ipairs(Controls.definitions(c)) do result[#result+1]=definition end
        end
        return result
    end
    local definitions = definitionsFor()
    local runtime
    local handlers = {}
    function handlers.checkpoint()
        return {client={version=client.version,readUpTo=client.readUpTo}}
    end
    function handlers.append(event)
        local result = client:append(event)
        if authority then authority:observe(result) end
        return result
    end
    function handlers.lease() return client:lease(ctx.task.taskId) end
    function handlers.skill_choice(input)
        local result=client:request(input.method,input.path,input.body)
        if result.task then client.version=result.task.version end
        return result
    end
    function handlers.attachment(input)
        return Documents.keep(client,ctx.task,input.call,input.result,{upload=input.upload})
    end
    function handlers.wake(input)
        local result=client:request("POST",client.path .. "/wake",input)
        if result.task then client.version=result.task.version end
        return result
    end
    function handlers.wake_status(input)
        local cursor=input.afterCursor or input.readUpTo or 0
        local after=input.afterCursor~=nil or not input.afterEventId
        repeat
            local page=client:request("GET",client.path .. "/events?after=" .. cursor)
            for _,event in ipairs(page.events or {}) do
                if not after then after=eventID(event)==input.afterEventId
                elseif event.title=="deferred" and event.body==input.note and
                    (not input.actorId or event.actorId==input.actorId) then return {found=true} end
            end
            if not page.hasMore then return {found=false} end
            assert(page.cursor and page.cursor>cursor,"wake history cursor did not advance")
            cursor=page.cursor
        until false
    end
    function handlers.model(input)
        local started = core.monotonic_ms()
        local ok, reply = pcall(model.request, model, input.messages, input.definitions,
            input.seat and {seat=input.seat} or ctx.task)
        if not ok then
            if type(reply) ~= "table" or not reply.usage then error(reply,0) end
            reply = {error=reply.message or reply.reason,reason=reply.reason,
                usage=reply.usage,modelAlias=reply.modelAlias,model=reply.model,items=json.array(),calls=json.array()}
        end
        reply.durationMs = core.monotonic_ms()-started
        return secrets.value(reply)
    end
    function handlers.tool(call)
        if not client.leasedAt or core.monotonic_ms()-client.leasedAt >= 30000 then client:lease(ctx.task.taskId) end
        if ctx.beforeTool then ctx.beforeTool(call, runtime.state.data) end
        local started = core.monotonic_ms()
        local result = registry:invoke(call)
        result.output,result.whole=secrets.text(result.output),secrets.text(result.whole)
        if ctx.transformResult then ctx.transformResult(call,result) end
        local clean = secrets.value({output=result.output,whole=result.whole,raw=serializable(result.raw),
            error=result.error,foreign=result.foreign,outputChangedBy=result.outputChangedBy,durationMs=core.monotonic_ms()-started})
        if ctx.afterTool then clean.provenance=ctx.afterTool(call,clean,runtime.state.data) end
        if ctx.keepResult then ctx.keepResult(call,clean) end
        return clean
    end
    local contextMeta=copy(ctx.context or {recorded={},settled={},sent=0})
    contextMeta.input=nil
    local initial = {taskId=ctx.task.taskId,attemptId=core.identifier(),data={
        woke=eventID((ctx.history or {})[#(ctx.history or {})]),input=ctx.input,turn=0,
        cause=eventID((ctx.history or {})[#(ctx.history or {})]),foreign=ctx.foreign or false,
        revision=ctx.revision,worktreeId=ctx.worktreeId,role=ctx.role,roleVersion=ctx.roleVersion,
        definitions=definitions,context=contextMeta,spent=0,client={version=client.version,readUpTo=client.readUpTo}}}
    runtime = Runtime.open(ctx.root,ctx.stateName,initial,handlers)
    initial=nil
    local savedClient=runtime.state.data.client
    if savedClient then client.version,client.readUpTo=savedClient.version,savedClient.readUpTo end
    local function advance(phase,changes) return runtime:advance(phase,changes) end
    local function contextOf(d)
        local state=copy(d.context);state.input=d.input;return state
    end
    local function metadata(state)
        local result=copy(state);result.input=nil;return result
    end
    local function append(event,next,changes,refused)
        changes=changes or {}
        if ctx.provenanceState then changes.provenance=ctx.provenanceState() end
        event.causedBy = event.causedBy or runtime.state.data.cause
        local id = event.requestId or runtime.state.attemptId .. "/" .. (runtime.state.seq+1)
        return runtime:issue({kind="append",input=client:prepare(event,id),next=next,
            refused=refused or ((event.action or event.kind=="confirmation") and "authority_refused" or nil)},changes)
    end
    local function wake(effect)
        -- SleepTask computes now+delay and has no idempotency key. A second
        -- POST after waking would put the task back to sleep for a full delay.
        local last=(runtime.state.last or {}).value or {}
        effect.replay="never"
        effect.observation={afterEventId=eventID(last) or runtime.state.data.cause,
            afterCursor=last.cursor,readUpTo=client.readUpTo,note=effect.input.note,
            actorId=ctx.actorId or ctx.task.assigneeId}
        return runtime:issue(effect)
    end
    local phases = {}
    function phases.prepare(d)
        local tools = json.array()
        for _, definition in ipairs(definitions) do
            local tool = registry:find(definition.name)
            tools[#tools+1] = {name=tool and tool.name or definition.name,class=tool and tool.class or nil,program=tool and tool.program,
                digest=fs.sha256(definition.name .. "\n" .. definition.description .. "\n" .. json.encode(definition.parameters))}
        end
        append({kind="message",title="attempt_entered",level="trace",imprint={
            build=ctx.build or require("version"),roleVersion=d.roleVersion,
            workspaceId=ctx.workspaceId,worktreeId=d.worktreeId,worktreeRevision=d.revision,
            role=block(d.role),facts=block(ctx.facts),notebook=block(ctx.notebook),
            colleagues=block(ctx.colleagues),craftsBlock=block(ctx.skills),tools=tools,
            seat=ctx.task.seat or ctx.config.model.alias,maxTurns=ctx.maxTurns}},"entered")
    end
    function phases.entered(d)
        local carry=authority and authority:pending() or {}
        advance(#carry>0 and "tool_decide" or "fold_ready",{cause=eventID(runtime.state.last.value),
            carry=carry,carryIndex=1,carryMode=#carry>0,step=core.identifier()})
    end
    function phases.fold_ready(d)
        local job=Context.planFold(ctx.task,ctx.history or {},{model=ctx.config.model,actorId=ctx.actorId,root=ctx.root})
        advance(job and "compact_start" or "model_ready",{compactJob=job or json.null})
    end
    function phases.model_ready(d)
        if d.turn >= ctx.maxTurns then
            append({kind="failure",title="exhausted",state="failed",body="The attempt reached its configured turn limit."},"finished",
                {outcome="exhausted"})
        else
            local context=contextOf(d)
            if ctx.beforeTurn and d.mutatedTurn~=d.turn+1 then
                local input,changed=ctx.beforeTurn(context.input,d.turn+1)
                advance("model_ready",{input=input,inputChangedBy=changed,mutatedTurn=d.turn+1});return
            end
            local seat=model:open(ctx.task.seat)
            local reserve=ctx.config.model.maxAnswer or math.min(seat.maxOutput or 0,32000)
            local compactor=ctx.config.model.compactor
            local compactSeat=compactor and compactor~="" and model:open(compactor) or nil
            local job=Context.compact(context,{seat=seat,definitions=d.definitions,model=ctx.config.model,
                compactorSeat=compactSeat,compactorReserve=ctx.config.model.maxAnswer or math.min((compactSeat or {}).maxOutput or 0,32000),
                budgetLeft=ctx.task.budgetLeft,spent=d.spent,toolOutput=registry.toolOutput,reserve=reserve,
                registry=registry,recordReader="read_original"})
            local measured=Context.measure(context,d.definitions,seat,reserve)
            if not job and not measured.fits then
                append({kind="failure",title="context_full",errorCode="context_full",state="failed",
                    body="The task context no longer fits this model window. Use a model with a larger window or start a focused task."},
                    "finished",{outcome="context_full"})
                return
            end
            runtime:issue({kind="lease",input={},next=job and "compact_start" or "model_start"},
                {context=metadata(context),compactJob=job or json.null})
        end
    end
    function phases.compact_start(d)
        local step=core.identifier()
        append({kind="message",level="trace",title="compaction",phase="start",stepId=step,
            requestId=step .. "/start"},"compact_request",{compactStep=step})
    end
    function phases.compact_request(d)
        local job=d.compactJob
        runtime:issue({kind="model",input={messages=job.input,definitions=json.array(),seat=job.alias},next="compact_record"})
    end
    function phases.compact_record(d)
        local reply=runtime.state.last.value
        local replacement,event=Context.complete(contextOf(d),d.compactJob,reply)
        event.stepId,event.requestId=d.compactStep,d.compactStep .. "/done"
        append(event,"compact_recorded",{compacted=replacement,
            spent=d.spent+((reply.usage.chargedUnits or 0)>0 and reply.usage.chargedUnits or reply.usage.units or 0)})
    end
    function phases.compact_recorded(d)
        local compacted=d.compacted
        if d.compactJob.kind=="fold" then
            local history=Sequence.copy(ctx.history);history[#history+1]=runtime.state.last.value
            compacted=Context.prepare(ctx.task,history,ctx.contextOptions or {role=d.role,actorId=ctx.actorId,registry=registry})
        end
        advance("model_ready",{input=compacted.input,context=metadata(compacted),compacted=json.null,
            cause=eventID(runtime.state.last.value)})
    end
    function phases.model_start(d)
        local step = core.identifier()
        append({kind="message",level="trace",title="thinking",phase="start",stepId=step,
            requestId=step .. "/think/start",inputChangedBy=d.inputChangedBy},"model_request",{step=step,turn=d.turn+1})
    end
    function phases.model_request(d)
        runtime:issue({kind="model",input={messages=d.input,definitions=d.definitions},next="model_record"})
    end
    function phases.model_record(d)
        local reply = runtime.state.last.value
        local event = copy(reply.usage)
        event.kind,event.level,event.title = "message","trace",#reply.calls > 0 and "tool_choice" or "thinking"
        event.body,event.stepId,event.requestId = reply.answer or reply.error,d.step,d.step .. "/think"
        event.durationMs,event.modelAlias,event.model = reply.durationMs,reply.modelAlias,reply.model
        append(event,"model_recorded",{reply=reply})
    end
    function phases.model_recorded(d)
        local context=contextOf(d)
        Context.counted(context,d.reply.inputTokens,d.reply.outputTokens)
        local input = Sequence.copy(d.input)
        for _,item in ipairs(d.reply.items or {}) do input[#input+1]=item end
        advance(d.reply.error and "model_failed" or (#d.reply.calls == 0 and "result" or "tool_decide"),
            {input=input,context=metadata(context),callIndex=1,cause=eventID(runtime.state.last.value),authorityEvent=json.null,
                spent=d.spent+((d.reply.usage.chargedUnits or 0)>0 and d.reply.usage.chargedUnits or d.reply.usage.units or 0)})
    end
    function phases.model_failed(d)
        advance("breakdown",{breakdown={message=d.reply.error,reason=d.reply.reason}})
    end
    local function callAt(d)
        return d.carryMode and (d.carry[d.carryIndex] or {}).call or d.reply and d.reply.calls[d.callIndex]
    end
    function phases.tool_decide(d)
        local call = callAt(d)
        if not call and not (d.carryMode and d.carry[d.carryIndex]) then advance("model_ready"); return end
        if not d.carryMode and ctx.controls and Controls.handles(call.name) then
            advance("control_decide");return
        end
        if call and not d.carryMode and ctx.beforeCall then
            local allowed,reason=ctx.beforeCall(call,registry:find(call.name),d)
            if not allowed then
                advance("tool_record",{toolReply={output=reason,error=true,errorCode="mutator_refused",foreign=false},
                    provenance=ctx.provenanceState and ctx.provenanceState(),callCause=d.cause,invoked=false})
                return
            end
        end
        local context = copy(d.carryMode and d.carry[d.carryIndex] or {})
        context.stepId,context.causedBy,context.foreign=d.step,d.cause,d.foreign
        context.event=d.authorityEvent ~= json.null and d.authorityEvent or nil
        context.error=d.authorityError ~= json.null and d.authorityError or nil
        local decision = authority and authority:decide(call,context) or {status="execute"}
        if decision.event then
            append(decision.event,"authority_recorded")
        elseif decision.status == "execute" then
            local tool = registry:find(call and call.name)
            local control=copy(d.control)
            if tool then control.citation=nil end
            if d.carryMode then
                advance("tool_run",{callCause=decision.causedBy or d.cause,invoked=true,control=control})
                return
            end
            append({kind="message",title=tool and tool.name or call.name,level="trace",phase="start",
                stepId=d.step,quoted=secrets.text(call.arguments or json.encode(call.args)),
                action=decision.approvedAction,causedBy=decision.causedBy or d.cause,
                risk=tool and tool.class == "attended" and "attended" or nil,
                source=tool and tool.source or nil,argsChangedBy=d.argsChangedBy,requestId=d.step .. "/" .. call.id .. "/start"},"tool_run",
                {callCause=decision.causedBy or d.cause,invoked=true,control=control})
        else
            advance("tool_record",{toolReply={output=decision.reason or decision.status,
                error=decision.status == "refused",errorCode="mutator_refused",foreign=false},queued=d.queued or decision.status == "defer",
                callCause=d.cause,invoked=false})
        end
    end
    local function controlContext(d)
        local c=copy(ctx.controlContext)
        c.task,c.history,c.stepId,c.causedBy=ctx.task,ctx.history,d.step,d.cause
        c.state,c.calls,c.index,c.registry,c.authority=d.control,d.reply.calls,d.callIndex,registry,authority
        c.definitions=d.definitions
        c.event=d.controlEvent~=json.null and d.controlEvent or nil
        c.error=d.controlError~=json.null and d.controlError or nil
        return c
    end
    function phases.control_decide(d)
        local plan=Controls.decide(callAt(d),controlContext(d))
        advance("control_apply",{controlPlan=plan,control=plan.state,controlIndex=1})
    end
    function phases.control_apply(d)
        local plan=d.controlPlan
        local event=(plan.events or {})[d.controlIndex]
        if event then append(event,"control_recorded",nil,"control_refused");return end
        if plan.effect then
            local effect=copy(plan.effect);effect.next="control_completed";effect.refused="control_completed"
            if effect.kind=="wake" then wake(effect) else runtime:issue(effect) end
            return
        end
        if plan.refreshSkills and ctx.onSkills then ctx.onSkills(plan) end
        if plan.task then ctx.task=plan.task end
        local input=Sequence.copy(d.input)
        if plan.skillText then input[#input+1]={role="system",content=plan.skillText} end
        if plan.outcome then runtime:finish(plan.outcome);return end
        if plan.record==false then
            input[#input+1]={type="function_call_output",call_id=callAt(d).id,output=plan.output or "Done."}
            advance("tool_decide",{input=input,callIndex=d.callIndex+1,control=plan.state,
                definitions=plan.refreshDefinitions and definitionsFor(plan.state) or d.definitions,
                controlEvent=json.null,controlError=json.null,controlPlan=json.null})
            return
        end
        advance("tool_record",{toolReply={output=plan.output or "Done.",error=plan.error,foreign=false},
            callCause=d.cause,invoked=false,control=plan.state,queued=d.queued or plan.queued,
            definitions=plan.refreshDefinitions and definitionsFor(plan.state) or d.definitions,
            input=input,selectedSkills=plan.skills or d.selectedSkills,
            controlEvent=json.null,controlError=json.null,controlPlan=json.null})
    end
    function phases.control_recorded(d)
        if d.controlPlan.continuation then
            advance("control_decide",{controlEvent=runtime.state.last.value,controlError=json.null})
        else advance("control_apply",{controlIndex=d.controlIndex+1}) end
    end
    function phases.control_refused(d)
        advance("control_decide",{controlEvent=json.null,controlError=runtime.state.last.error})
    end
    function phases.control_completed(d)
        local last=runtime.state.last
        local plan=Controls.complete(d.controlPlan,last.error and {error=last.error} or last.value,controlContext(d))
        if plan.fatal then error(plan.fatal,0) end
        advance("control_apply",{controlPlan=plan,control=plan.state,controlIndex=1})
    end
    function phases.authority_recorded(d)
        advance("tool_decide",{authorityEvent=runtime.state.last.value,authorityError=json.null})
    end
    function phases.authority_refused(d)
        local err=runtime.state.last.error
        if d.carryMode then
            advance("tool_decide",{authorityError=err,authorityEvent=json.null})
        else
            advance("tool_record",{toolReply={output=err.message or err.reason or "Action was refused.",
                error=true,errorCode="mutator_refused",foreign=false},callCause=d.cause,invoked=false})
        end
    end
    function phases.tool_run(d)
        local call,tool = callAt(d),registry:find(callAt(d).name)
        runtime:issue({kind="tool",input=call,next="tool_returned",replay=tool and tool.class == "read" and "safe" or "never"},
            {callStart=eventID(runtime.state.last.value)})
    end
    function phases.tool_returned(d)
        local result=runtime.state.last.value
        advance(ctx.keepWhole and "tool_keep" or "tool_record",{toolReply=result,provenance=result.provenance or d.provenance,
            definitions=result.definitions and definitionsFor(d.control) or d.definitions})
    end
    function phases.tool_keep(d)
        local call=callAt(d)
        local tool=registry:find(call.name) or {}
        local composes=type(tool.composes)=="function" and tool.composes(call.args) or tool.composes
        local upload=Documents.prepare(ctx.task,call,d.toolReply,{stepId=d.step,composed=(composes or tool.delegates or tool.echoes)==true,
            title=tool.title,nativeName=tool.name,toolOutput=registry.toolOutput})
        if upload then runtime:issue({kind="attachment",replay="delivery",input={call=call,result=d.toolReply,upload=upload},next="tool_kept"})
        else advance("tool_record") end
    end
    function phases.tool_kept(d) advance("tool_record",{toolReply=runtime.state.last.value}) end
    function phases.tool_record(d)
        local call,result = callAt(d),d.toolReply
        if not call then
            runtime:finish("waiting")
            return
        end
        local tool = registry:find(call.name)
        append({kind="message",level=not (d.carryMode and d.invoked) and "trace" or nil,
            title=tool and tool.name or call.name,stepId=d.step,
            body=result.output,quoted=secrets.text(call.arguments or json.encode(call.args)),
            errorCode=result.errorCode or (result.error and "tool_error" or nil),durationMs=result.durationMs,causedBy=d.callCause,
            outputChangedBy=result.outputChangedBy,
            requestId=d.step .. "/" .. call.id},"tool_recorded")
    end
    function phases.tool_recorded(d)
        local input = Sequence.copy(d.input)
        local context=contextOf(d)
        context.recorded[callAt(d).id]=eventID(runtime.state.last.value)
        if d.carryMode then
            input[#input+1]={role="user",content="Recorded outcome of the approved action " ..
                callAt(d).name .. ":\n" .. d.toolReply.output}
            local more=d.carryIndex<#d.carry
            advance(more and "tool_decide" or "fold_ready",{input=input,context=metadata(context),carryIndex=d.carryIndex+1,carryMode=more,
                cause=eventID(runtime.state.last.value),foreign=d.foreign or d.toolReply.foreign,
                authorityEvent=json.null,authorityError=json.null,invoked=false})
        else
            input[#input+1]={type="function_call_output",call_id=callAt(d).id,output=d.toolReply.output}
            advance("tool_decide",{input=input,context=metadata(context),callIndex=d.callIndex+1,cause=eventID(runtime.state.last.value),
                foreign=d.foreign or d.toolReply.foreign,authorityEvent=json.null,authorityError=json.null,invoked=false})
        end
    end
    function phases.result(d)
        local citation=(d.control or {}).citation or {}
        append({kind=d.queued and "message" or "result",title="result",body=d.reply.answer,
            quoted=citation.quote,source=citation.source,
            state=not d.queued and "completed" or nil},"finished",{outcome=d.queued and "waiting" or "completed"})
    end
    function phases.finished(d) runtime:finish(d.outcome) end
    function phases.breakdown(d)
        local plan=Failures.plan(ctx.history,ctx.task,d.breakdown,{stepId=d.step or runtime.state.attemptId,
            causedBy=d.cause,woke=d.woke,modelAlias=(d.reply or {}).modelAlias,model=(d.reply or {}).model,
            gateway=d.breakdown.gateway,wakeFailed=d.wakeFailed})
        if plan.event then append(plan.event,"breakdown_recorded",{failurePlan=plan})
        else runtime:finish(plan.outcome) end
    end
    function phases.breakdown_recorded(d)
        if d.failurePlan.wake then wake({kind="wake",input=d.failurePlan.wake,next="deferred",refused="wake_refused"})
        else runtime:finish(d.failurePlan.outcome or "retry") end
    end
    function phases.deferred() runtime:finish("deferred") end
    function phases.wake_refused() advance("breakdown",{wakeFailed=true}) end
    function phases.wake_reconcile(d)
        runtime:issue({kind="wake_status",replay="safe",input=d.wakeObservation,next="wake_reconciled"})
    end
    function phases.wake_reconciled()
        -- Absence is not proof that an interrupted POST never committed. Keep
        -- the uncertainty explicit instead of sending it again or claiming sleep.
        runtime:finish(runtime.state.last.value.found and "deferred" or "wake_outcome_unknown")
    end
    function phases.settle_superseded(d)
        local event=copy(d.settlement)
        client.version=ctx.task.version
        event.version=client.version
        -- The server explicitly refused the old version. Only an already
        -- obtained observation/charge is carried forward, never an action or
        -- completion of the changed task. The old read cursor stays exact.
        append(event,"superseded")
    end
    function phases.superseded() runtime:finish("superseded") end
    function phases.uncertain(d)
        if d.uncertainKind=="model" then
            append({kind="failure",title="failed",errorCode="model_outcome_unknown",spendUnknown=true,
                body="The model request was interrupted. Its result and charge could not be recovered; the paid request was not repeated.",
                state="failed"},"finished",{outcome="model_outcome_unknown"})
        else
            local call=callAt(d)
            append({kind="question",title="question",state="input_required",errorCode="tool_outcome_unknown",
                body="The action " .. (call and call.name or "tool") .. " was interrupted after it started. Did it take effect?",
                options=json.array({{label="It happened"},{label="It did not happen"}}),
                addresseeIds=json.array({ctx.task.ownerId}),causedBy=d.carryMode and d.callCause or d.callStart or d.cause},
                "finished",{outcome="waiting"})
        end
    end

    local ok,why = pcall(function()
        local pending=runtime.state.pending
        if pending and pending.kind=="wake" and pending.replay~="never" then
            -- Older checkpoints called this relative-time POST safe. Correct
            -- its replay rule before resume persists or executes anything.
            runtime.state=copy(runtime.state)
            runtime.state.pending=copy(pending)
            runtime.state.pending.replay="never"
            pending=runtime.state.pending
        end
        if ctx.historyChanged and pending and pending.kind~="append" and pending.replay~="never" then
            runtime:finish("superseded")
        elseif runtime.state.mode == "waiting" or runtime.state.mode == "parked" then runtime:resume() end
        local settling={model_record=true,compact_record=true,tool_returned=true,tool_keep=true,tool_kept=true,
            tool_record=true,finished=true,uncertain=true,breakdown=true,breakdown_recorded=true,deferred=true,wake_refused=true,
            wake_reconcile=true,wake_reconciled=true}
        while true do
            if runtime.state.mode=="parked" and runtime.state.pending then
                local err=runtime.state.error or {}
                local pending=runtime.state.pending
                if runtime.state.certainty=="not_started" and type(err)=="table" and err.reason=="changed_meanwhile" then
                    if (ctx.task.version or 0) <= (runtime.state.data.client.version or 0) then break end
                    local event=pending.kind=="append" and pending.input
                    if event and event.kind=="message" and not event.state and not event.action and event.phase~="start" then
                        runtime:recover("settle_superseded",{settlement=event})
                    else runtime:finish("superseded") end
                elseif runtime.state.certainty=="not_started" or type(err)=="table" and err.reason=="mutator_broken" then
                    -- A refused append cannot use the same refused version to
                    -- report its own refusal. Leave delivery to the caller.
                    if runtime.state.pending.kind=="append" then break end
                    runtime:recover("breakdown",{breakdown=err})
                elseif pending.kind=="skill_choice" then
                    -- Selection is observable in the next lease/catalogue.
                    -- Start fresh to read it instead of asking the person to
                    -- diagnose an internal PUT or repeating it blindly.
                    runtime:finish("superseded")
                elseif pending.kind=="wake" then
                    runtime:recover("wake_reconcile",{wakeObservation=pending.observation or {
                        afterEventId=runtime.state.data.cause,readUpTo=client.readUpTo,
                        actorId=ctx.actorId or ctx.task.assigneeId,note=pending.input.note}})
                else runtime:recover("uncertain",{uncertainKind=pending.kind}) end
            end
            if runtime.state.mode~="active" then break end
            if ctx.historyChanged and not settling[runtime.state.phase] and runtime.state.phase~="settle_superseded"
                and runtime.state.phase~="superseded" then runtime:finish("superseded");break end
            local phase = assert(phases[runtime.state.phase], "unknown attempt phase: " .. tostring(runtime.state.phase))
            local ran,err=pcall(phase,runtime.state.data)
            if not ran then
                if runtime.state.phase=="breakdown" or runtime.state.mode~="active" then error(err,0) end
                local problem=type(err)=="table" and err or {message=tostring(err)}
                advance("breakdown",{breakdown=secrets.value({reason=problem.reason,message=problem.message,
                    status=problem.status,gateway=problem.gateway})})
            end
        end
    end)
    local state = runtime.state
    if state.mode=="done" then
        local d=state.data
        runtime:finish(state.outcome,{client=d.client,revision=d.revision,worktreeId=d.worktreeId,
            turn=d.turn,reply={answer=(d.reply or {}).answer},woke=d.woke})
        state=runtime.state
    end
    runtime:close()
    if not ok then error(why,0) end
    return {outcome=state.outcome or state.mode,answer=(state.data.reply or {}).answer,
        turns=state.data.turn,revision=state.data.revision,reason=state.reason,version=client.version,
        resume=state.outcome=="superseded" or state.outcome=="retry" or state.outcome=="deferred" or state.reason=="changed_meanwhile" or
            (state.mode=="waiting" and state.certainty~="not_started" and
            state.pending and state.pending.replay~="never") or false}
end
return Runner
