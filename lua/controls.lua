-- The small agent's control calls bypass the ordinary tool/authority chain.
-- decide() performs no IO. Persist its state and ordered events, then prepare
-- and append each event through the runner. Only after all acknowledgements
-- may outcome finish the attempt. consumeRest forbids later tools in the reply.
-- Skill choice is a separate effect: persist the plan before executing it and
-- pass its decoded reply (or {error=structuredError}) to complete(). A lost PUT
-- reply is an unknown outcome, never a safe retry. Registry/skill installation
-- and definition refresh belong to the runner after refreshSkills is returned.
-- ctx supplies task, history, stepId, causedBy and persisted control state.
-- For questions pass the full model calls and current index; for escalation
-- pass authority, then re-enter decide with the confirmed event or named error.
-- catalogue is the permitted full catalogue; pinned selects its frozen records.
-- All control calls bypass repeat counters. Effects declare their replay rule;
-- complete().fatal must follow the attempt's normal failure/uncertainty path.
local json = require("json")
local Registry = require("registry")
local Controls = {}
local names = {describe_tool=true, ask_human=true, cannot_do=true, come_back_later=true,
    escalate_action=true, cite_source=true, use_skill=true}
local classes = {"no_tool", "tool_failed", "unavailable", "no_access", "not_found", "off_task", "guard", "other"}
local function trim(value) return type(value) == "string" and value:match("^%s*(.-)%s*$") or "" end
local function list(value) return type(value) == "table" and value ~= json.null and value or {} end
local function copy(value) local out = {}; for k,v in pairs(value or {}) do out[k]=v end; return out end
local function object(properties, required)
    return {type="object",properties=properties,required=json.array(required or {}),additionalProperties=false}
end
local function stringField(description) return {type="string",description=description} end
local function escape(value) return value:gsub("[^%w%-._~]",function(c) return ("%%%02X"):format(c:byte()) end) end
local function arguments(call) return type(call.args) == "table" and call.args ~= json.null and call.args or {} end
local function result(ctx, output)
    return {events=json.array(),state=copy(ctx.state),output=output}
end
local function event(ctx, entry, suffix)
    entry.stepId,entry.causedBy=ctx.stepId,ctx.causedBy
    entry.requestId=assert(ctx.stepId,"control requires stepId") .. "/" .. suffix
    return entry
end

function Controls.handles(name) return names[name] == true end

function Controls.choiceOpen(ctx)
    if (ctx.state or {}).skillChoiceClosed or #(ctx.catalogue or {}) == 0 or #((ctx.task or {}).skills or {}) > 0 then return false end
    for _, line in ipairs(ctx.history or {}) do if line.title == "skill_dropped" then return false end end
    return true
end

local function choiceSummary(text)
    text=trim(text)
    local first=Registry.firstSentence(text)
    if utf8.len(first) > 160 then first=trim(first:sub(1,utf8.offset(first,161)-1)) .. "…" end
    return first
end

function Controls.definitions(ctx)
    ctx=ctx or {}
    local definitions=json.array()
    local function add(name, description, parameters)
        definitions[#definitions+1]={type="function",name=name,description=description,parameters=parameters}
    end
    local folded=ctx.folded
    if folded==nil and ctx.registry then local _;_,folded=ctx.registry:definitions((ctx.state or {}).described or {}) end
    if folded then
        add("describe_tool","Give the full description and arguments of a declared tool by its model name. Some tools are declared short: ask before their first use. After this call the tool stays fully declared for the rest of this work.",
            object({name=stringField("The tool's name exactly as declared.")},{"name"}))
    end
    if Controls.choiceOpen(ctx) then
        local catalogue={"Choose the skills this errand will work by, from this catalogue:"}
        for _, skill in ipairs(ctx.catalogue) do catalogue[#catalogue+1]="- " .. skill.name .. " — " .. choiceSummary(skill.summary) end
        add("use_skill",table.concat(catalogue,"\n"),object({skills={type="array",items={type="string"},
            description="Skill names exactly as in the catalogue, in their order of importance."}},{"skills"}))
    end
    add("ask_human","Ask when missing information is neither in the task nor tools, or the decision belongs to the person. Work stops until they answer. Ask up to three independent questions in one reply; calls after a question are set aside. Put questions last.",object({
        question=stringField("One short question the person can answer."),
        note=stringField("Where the work stands: what was found and what remains, for whoever resumes it."),
        options={type="array",description="Two to four distinct choices with consequences; omit for a free answer. Never offer 'other': a free answer is always possible.",
            items=object({label=stringField("Up to five words."),hint=stringField("One sentence saying what happens on choosing it.")},{"label","hint"})},
        who={type="array",items={type="string"},description="Colleague identifiers; omit to ask the task's owner."},
        proposeMark=object({toUserId={type="string"},amount={type="integer"},reason={type="string"},taskId={type="string"}},
            {"toUserId","amount","reason","taskId"})},{"question","note"}))
    add("cannot_do","Finish as failed only when the task cannot be done: access is closed, information cannot be found, or the request is outside your duties. If a clarification can help and asking is allowed, use ask_human.",object({
        reason=stringField("Why the task could not be done, in words for the person."),
        missing=stringField("What was missing: information, access or an ability."),
        class={type="string",enum=json.array(classes),description="The kind of obstacle; use other if none fits."}},{"reason","class"}))
    add("come_back_later","Set this task aside until something outside happens, such as a publication, deadline or expected reply, then continue with its conversation intact. Use ask_human when a person's decision is needed. Do not defer work you can do now.",object({
        minutes={type="integer",minimum=1,maximum=10080,description="Minutes until continuing: at least one, at most one week."},
        note=stringField("What you will do on waking and what outside event you are waiting for.")},{"minutes","note"}))
    add("escalate_action","Ask the person to decide about an action blocked by the guard only after finding no safe alternative. Name the blocked action and explain why there is no other way. A hard denial cannot be escalated; use cannot_do if it prevents the task.",object({
        id=stringField("Blocked approval identifier exactly as returned by the guard."),
        why=stringField("Why no safe path exists; the person reads this before deciding.")},{"id","why"}))
    add("cite_source","Name what your next answer rests on when it rests on a particular document. Call before answering. The person sees your words about the source, not a verified extract. A later tool call drops this citation.",object({
        quote=stringField("The line your answer rests on, word for word."),
        source=stringField("Where the person can check the line: the document or source address.")},{"quote","source"}))
    return definitions
end

local function cannot(ctx, body, class, suffix)
    local out=result(ctx)
    out.events[1]=event(ctx,{kind="failure",title="cannot",body=body,state="failed",
        errorCode="cannot_do",errorDetail=class},suffix)
    out.outcome,out.consumeRest="gave_up",true
    return out
end

local function stops(history)
    local seen,count={},0
    for i,line in ipairs(history or {}) do
        if line.kind == "question" then
            local key=trim(line.stepId) ~= "" and line.stepId or "/" .. (line.eventId or tostring(i))
            if not seen[key] then seen[key]=true;count=count+1 end
        end
    end
    return count
end

local function question(out,call,ctx)
    local args,addressees,missed,seen=arguments(call),json.array(),{},{}
    for _, who in ipairs(list(args.who)) do
        who=trim(who)
        if who ~= "" then
            if who == ctx.task.ownerId or (ctx.colleagues or {})[who] then
                if not seen[who] then addressees[#addressees+1]=who;seen[who]=true end
            else missed[#missed+1]=who end
        end
    end
    if #addressees == 0 then addressees[1]=ctx.task.ownerId end
    if #missed > 0 then
        out.events[#out.events+1]=event(ctx,{kind="message",level="trace",title="addressee_unknown",
            body="Unknown colleague identifiers: " .. table.concat(missed,", ") .. ". The question uses the available addressees or the task owner."},call.id .. "/addressee")
    end
    out.events[#out.events+1]=event(ctx,{kind="question",title="question",
        body=trim(args.question) ~= "" and args.question or "A clarification is needed, but the question was not put.",
        state="input_required",addresseeIds=addressees,options=type(args.options) == "table" and args.options or nil,
        proposeMark=type(args.proposeMark) == "table" and args.proposeMark or nil},call.id)
end

local function ask(call,ctx)
    local args,out=arguments(call),result(ctx)
    local budget=ctx.task.asking == "never" and 0 or ctx.task.asking == "always" and 15 or 5
    if budget == 0 then
        if not out.state.toldNotToAsk then
            out.state.toldNotToAsk=true
            out.output="The person asked not to be asked in this errand: decide it yourself on what you have, or finish by saying what stopped you and what you would have asked."
            return out
        end
        return cannot(ctx,"The person asked not to be asked, and the task could not be settled without them. The question was: " .. trim(args.question),"not_asked","out-of-stops")
    end
    local count=stops(ctx.history)
    if count >= budget then
        return cannot(ctx,"This errand has already stopped on a person " .. count .. " times and is no nearer done. The last question was: " .. trim(args.question),"out_of_stops","out-of-stops")
    end
    if trim(args.note) == "" then
        out.output="The question was not put. Say in note where the work stands: what has been found and what remains, then ask again."
        return out
    end
    out.events[1]=event(ctx,{kind="message",title="handover",body=trim(args.note)},"handover")
    question(out,call,ctx)
    local asked,aside=1,{}
    for index=(ctx.index or 1)+1,#(ctx.calls or {}) do
        local later=ctx.calls[index]
        if later.name == "ask_human" and asked < 3 then question(out,later,ctx);asked=asked+1
        else
            local tool=ctx.registry and ctx.registry:find(later.name)
            aside[#aside+1]=tool and tool.name or later.name
        end
    end
    if #aside > 0 then
        out.events[#out.events+1]=event(ctx,{kind="message",level="trace",title="set_aside",
            body="The turn asked a person; " .. #aside .. " later calls were set aside: " .. table.concat(aside,", ")},"aside")
    end
    out.outcome,out.consumeRest="waiting",true
    return out
end

function Controls.decide(call,ctx)
    if not Controls.handles(call.name) then return nil end
    if call.error then
        local out=result(ctx,call.error);out.error=true
        if call.name=="describe_tool" or call.name=="cite_source" or call.name=="come_back_later" then out.record=false end
        return out
    end
    local args=arguments(call)
    if call.name=="describe_tool" then
        local out,name=result(ctx),trim(args.name)
        out.record=false
        local definition=ctx.registry:definition(name)
        if not definition then
            local declared={}
            for _,item in ipairs(ctx.definitions or ctx.registry:definitions()) do declared[#declared+1]=item.name end
            out.output="There is no tool " .. name .. ". The declared ones are: " .. table.concat(declared,", ")
            return out
        end
        out.state.described=copy(out.state.described)
        out.refreshDefinitions=not out.state.described[name]
        out.state.described[name]=true
        out.output=name .. " — declared in full from here on.\n\n" .. definition.description ..
            "\n\nArguments (JSON Schema):\n" .. json.encode(definition.parameters)
        return out
    end
    if call.name=="cite_source" then
        local out,quote,source=result(ctx),trim(args.quote),trim(args.source)
        out.record=false
        if quote=="" or source=="" then
            out.output="A citation needs both the line and where the person can check it. Name both, or answer without quoting."
            return out
        end
        local function bounded(text,limit)
            if #text<=limit then return text end
            while limit>0 and text:byte(limit+1)>=128 and text:byte(limit+1)<192 do limit=limit-1 end
            return text:sub(1,limit) .. "…"
        end
        out.state.citation={quote=bounded(quote,2000),source=bounded(source,200)}
        out.output="Noted. It will stand beside your answer as your own words about the source, not a verified extract. Do not repeat it in the answer. A later tool call drops it; name the source again after a lookup."
        return out
    end
    if call.name=="come_back_later" then
        local out=result(ctx)
        out.record=false
        if type(args.minutes)~="number" or args.minutes%1~=0 or args.minutes<1 or args.minutes>10080 then
            out.output="The delay is outside the allowed bounds: 1 to 10080 whole minutes.";return out
        end
        if trim(args.note)=="" then out.output="A deferral must say what will be done on waking.";return out end
        out.phase="defer"
        out.effect={kind="wake",replay="never",input={afterSeconds=args.minutes*60,note=trim(args.note)}}
        return out
    end
    if call.name == "ask_human" then return ask(call,ctx) end
    if call.name == "cannot_do" then
        local body=trim(args.reason) ~= "" and args.reason or "The executor could not carry out the task and named no reason."
        if trim(args.missing) ~= "" then body=body .. "\n\nWhat was missing: " .. trim(args.missing) end
        local class="other"
        for _,allowed in ipairs(classes) do if trim(args.class) == allowed then class=allowed end end
        return cannot(ctx,body,class,call.id)
    end
    if call.name == "escalate_action" then
        local out=result(ctx)
        local verdict=assert(ctx.authority,"escalation requires authority"):escalate(trim(args.id),trim(args.why),
            {stepId=ctx.stepId,callId=call.id,event=ctx.event,error=ctx.error})
        if verdict.event then out.events[1]=verdict.event;out.continuation="escalate_action" end
        out.output=verdict.reason or "The person has been asked to decide; independent work may continue."
        out.error=verdict.status == "refused"
        out.queued=not verdict.event and verdict.status == "defer"
        return out
    end
    local out=result(ctx)
    if not Controls.choiceOpen(ctx) then out.output="Skill selection is closed for this task. Work with its current skills.";return out end
    local selected,available=json.array(),{}
    for _,skill in ipairs(ctx.catalogue or {}) do available[skill.name]=true end
    for _,name in ipairs(list(args.skills)) do
        name=trim(name):lower()
        if name ~= "" then
            if not available[name] then out.output="There is no skill " .. name .. " in the catalogue.";return out end
            selected[#selected+1]=name
        end
    end
    if #selected == 0 then out.output="Name at least one skill, or work without one.";return out end
    out.phase,out.names="choose",selected
    out.effect={kind="skill_choice",replay="never",input={method="PUT",
        path="/api/v1/tasks/" .. escape(ctx.task.taskId) .. "/skills",body={skills=selected}}}
    return out
end

-- Completion still performs no IO. A successful choice returns the task/version
-- and pinned skills, or a safe read effect for the server's selected full skills.
-- A named HTTP refusal closes selection. Transport/5xx failures stay fatal and
-- must not be reported as a harmless model result or an unmade selection.
function Controls.complete(plan,response,ctx)
    local out={events=json.array(),state=copy(plan.state),names=plan.names,task=plan.task}
    local err=response.error
    if plan.phase=="defer" then
        if err then out.fatal=err
        else out.task,out.outcome,out.consumeRest=response.task,"deferred",true end
        return out
    end
    if err then
        if plan.phase == "choose" and type(err) == "table" and err.status and err.status >= 400 and err.status < 500 then
            out.state.skillChoiceClosed=true
            out.output="The skill was not taken: " .. (err.message or err.reason or "request refused") .. ". Work without a new choice."
            out.refreshDefinitions=true
        else out.fatal=err end
        return out
    end
    if plan.phase == "choose" then
        out.task=assert(response.task,"skill choice response requires task")
        if not ctx.pinned then
            out.phase="load"
            out.effect={kind="skill_choice",replay="safe",input={method="GET",path=plan.effect.input.path}}
            return out
        end
        out.skills=json.array()
        for _,name in ipairs(plan.names) do
            local found
            for _,skill in ipairs(ctx.catalogue or {}) do if skill.name == name then found=skill;break end end
            assert(found,"selected skill is absent from the pinned catalogue: " .. name)
            out.skills[#out.skills+1]=found
        end
    else
        assert(plan.phase == "load","unknown skill choice continuation")
        out.skills=assert(response.skills,"skill read response requires skills")
    end
    local descriptions={}
    for _,skill in ipairs(out.skills) do descriptions[#descriptions+1]="### " .. skill.name .. " - " .. (skill.summary or "") .. "\n\n" .. (skill.text or "") end
    out.skillText="Skills chosen for this errand refine the work; they do not replace the role.\n\n" .. table.concat(descriptions,"\n\n")
    out.output="Working by skills " .. table.concat(out.names,", ") .. ". The person has been told.\n\n" .. out.skillText
    out.state.skillChoiceClosed,out.refreshSkills,out.refreshDefinitions=true,true,true
    return out
end

return Controls
