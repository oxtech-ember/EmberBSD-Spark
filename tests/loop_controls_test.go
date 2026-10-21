package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestLoopControlDeclarationsAndBounds(t *testing.T) {
	script := `package.path=arg[1].."/?.lua;"..package.path
local json,Registry,Controls,Context=require("json"),require("registry"),require("controls"),require("context")
local registry=Registry.new()
local schema={type="object"}
registry:add{name="edge",class="read",description=string.rep("x",2048-#json.encode(schema)),parameters=schema,invoke=function()end}
local ctx={registry=registry,task={taskId="task"},state={},stepId="step"}
for _,definition in ipairs(Controls.definitions(ctx)) do assert(definition.name~="describe_tool") end
local boundary=registry:definitions({})
assert(#boundary[1].description+#json.encode(boundary[1].parameters)==2048,"the inclusive small-tool bound changed")
registry:add{name="report.build",class="read",description="Searches pt. 5 art. 42. More detail.",
    parameters={type="object",properties={deeply_specific_field={type="string",description=string.rep("details ",500)}}},invoke=function()end}
local function definitions(state)
    local defs,folded=registry:definitions(state.described or {})
    for _,d in ipairs(Controls.definitions{registry=registry,state=state,folded=folded}) do defs[#defs+1]=d end
    return defs
end
local initial=definitions({})
local byName={};for _,d in ipairs(initial) do byName[d.name]=d end
assert(byName.describe_tool and byName.cite_source and byName.come_back_later)
assert(byName.report_build.parameters.additionalProperties==true and not next(byName.report_build.parameters.properties))
local function schemaObject(definition)
    local read=json.reader(definition)
    local parts={}
    while true do local part=read(31);if not part then break end;parts[#parts+1]=part end
    local schema=json.decode(table.concat(parts)).parameters
    assert((getmetatable(schema.properties) or {}).__jsontype=="object",
        "folded JSON Schema properties must be an object on the wire")
end
schemaObject(byName.report_build)
assert(byName.report_build.description:find("Searches pt. 5 art. 42.",1,true) and not byName.report_build.description:find("More detail",1,true))
ctx.definitions=initial
local missing=Controls.decide({name="describe_tool",args={name="report_builder"}},ctx)
assert(missing.output:find("report_build",1,true) and not missing.state.described)
local unfolded=Controls.decide({name="describe_tool",args={name="report_build"}},ctx)
assert(unfolded.record==false and #unfolded.events==0 and unfolded.refreshDefinitions)
assert(unfolded.output:find("deeply_specific_field",1,true) and unfolded.output:find("declared in full",1,true))
assert(not ctx.state.described,"describe mutated the earlier checkpoint")
local restored=json.decode(json.encode(unfolded.state))
local whole=definitions(restored)
for _,d in ipairs(whole) do
    assert(d.name~="describe_tool","describe remained after the last folded tool was unfolded")
    if d.name=="report_build" then assert(d.parameters.properties.deeply_specific_field) end
end
local window={input=json.array(),window={}}
local before=Context.measure(window,initial)
Context.counted(window,before.occupied)
local after=Context.measure(window,whole,{contextWindow=before.occupied+100})
assert(after.occupied>before.occupied+100 and not after.fits,"unfolding was invisible to the model window")

local cited=Controls.decide({name="cite_source",args={quote=" "..string.rep(utf8.char(233),1100).." ",source=string.rep("s",300)}},ctx)
assert(cited.record==false and #cited.events==0)
assert(#cited.state.citation.quote==2003 and utf8.len(cited.state.citation.quote)==1001 and #cited.state.citation.source==203)
local invalid=Controls.decide({name="cite_source",args={quote="a line"}},ctx)
assert(not invalid.state.citation and invalid.output:find("check it",1,true))
local bounds=byName.come_back_later.parameters.properties.minutes
assert(bounds.minimum==1 and bounds.maximum==10080)
local wrong=Controls.decide({name="come_back_later",args={minutes=10081,note="Wait"}},ctx)
assert(not wrong.effect and not wrong.outcome and wrong.output:find("bounds",1,true))
wrong=Controls.decide({name="come_back_later",args={minutes=1,note=" "}},ctx)
assert(not wrong.effect and wrong.output:find("waking",1,true))
local later=Controls.decide({name="come_back_later",args={minutes=10080,note=" Check the publication. "}},ctx)
assert(#later.events==0 and later.effect.kind=="wake" and later.effect.replay=="never" and later.effect.input.afterSeconds==604800)
assert(later.effect.input.note=="Check the publication.")
local finished=Controls.complete(later,{task={taskId="task",version=7}},ctx)
assert(finished.outcome=="deferred" and finished.task.version==7 and #finished.events==0)
assert(Controls.complete(later,{error={status=403,reason="not_entrusted"}},ctx).fatal)
`
	entry := filepath.Join(t.TempDir(), "declarations.lua")
	if err := os.WriteFile(entry, []byte(script), 0600); err != nil {
		t.Fatal(err)
	}
	binary, _ := filepath.Abs("../build/agent-lua")
	modules, _ := filepath.Abs("../lua")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if output, err := exec.CommandContext(ctx, binary, entry, modules).CombinedOutput(); err != nil {
		t.Fatalf("loop control declarations: %v %s", err, output)
	}
}

func TestRunnerRestoresLoopControls(t *testing.T) {
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	entry := filepath.Join(directory, "loop-controls.lua")
	script := `package.path=arg[1].."/?.lua;"..package.path
local json,fs,Registry,Runner,Controls=require("json"),require("asenta.fs"),require("registry"),require("runner"),require("controls")
local root=assert(fs.root(arg[2],false))
local scenario,mode=arg[3],arg[4]
local remoteName=scenario.."-remote.json"
local remote=root:stat(remoteName) and json.decode(assert(root:read(remoteName))) or {version=1,turns=0,executed=0,wakes=0,events={}}
local function save() assert(root:write(remoteName,json.encode(remote))) end
local function copy(value) local out={};for k,v in pairs(value)do out[k]=v end;return out end
if scenario=="defer" and mode=="recover" then
    -- The initial lost response prevents lease until the server wakes the
    -- task. Recovery must not postpone it again after that wake has happened.
    remote.version=remote.version+1
    remote.events.woke={eventId="woke",cursor=remote.version,title="woke",kind="message",body="Check the publication."}
    save()
end
local client={version=remote.version,readUpTo=1,path="/api/v1/tasks/task"}
function client:prepare(event,id)
    local out=copy(event);out.requestId=out.requestId or id
    out.version=out.version or self.version;out.readUpTo=out.readUpTo or self.readUpTo;return out
end
function client:append(event)
    local old=remote.events[event.requestId]
    if old then self.version=remote.version;return old end
    assert(event.version==remote.version)
    assert(event.title~="cite_source" and event.title~="describe_tool" and event.title~="come_back_later","a control reply became a feed event")
    remote.version=remote.version+1;self.version=remote.version
    local out=copy(event);out.eventId="e"..remote.version;out.cursor=remote.version;out.actorId="executor"
    remote.events[event.requestId]=out;save()
    if scenario=="unfold" and mode=="crash" and remote.turns==1 and event.phase=="start" then
        local checkpoint=require("sequence").unpack(root,json.decode(assert(root:read(scenario..".json"))))
        assert(checkpoint.data.control.described.report_build and checkpoint.data.control.citation.quote=="Measured 7")
        os.exit(73)
    end
    return out
end
function client:lease() self.version=remote.version;return {taskId="task",version=self.version} end
function client:request(method,path,body)
    assert(scenario=="defer" or scenario=="wake_unknown")
    if method=="GET" then
        local after=assert(tonumber(path:match("^/api/v1/tasks/task/events%?after=(%d+)$")))
        local events=json.array()
        for _,event in pairs(remote.events)do if event.cursor>after then events[#events+1]=event end end
        table.sort(events,function(a,b)return a.cursor<b.cursor end)
        return {events=events,cursor=remote.version,hasMore=false}
    end
    assert(method=="POST" and path=="/api/v1/tasks/task/wake")
    assert(remote.wakes==0,"a lost wake acknowledgement caused a second relative-time POST")
    assert(body.afterSeconds==1020 and body.note=="Check the publication.")
    if scenario=="wake_unknown" then os.exit(73) end
    remote.wakes=remote.wakes+1;remote.version=remote.version+1
    remote.events.deferred={eventId="deferred",cursor=remote.version,kind="message",title="deferred",actorId="executor",
        body=body.note,quoted="2026-10-05T12:17:00Z"};save()
    if mode=="crash" then os.exit(73) end
    return {task={taskId="task",version=remote.version}}
end
local registry=Registry.new()
local function invoked()remote.executed=remote.executed+1;save();return "Read 8" end
registry:add{name="report.build",class="read",description="Build a report. More instructions.",invoke=invoked,
    parameters={type="object",properties={deeply_specific_field={type="string",description=string.rep("details ",500)}}}}
registry:add{name="device.read",class="read",invoke=invoked}
registry:add{name="device.send",class="external",invoke=invoked}
local authority={pending=function()return {} end,observe=function()end}
function authority:decide(call)
    assert(not Controls.handles(call.name),"control went through the tool gate")
    return {status=call.name=="device_send" and "defer" or "execute",reason="approval_pending"}
end
local function call(name,args) return {id=name,name=name,args=args,arguments=json.encode(args)} end
local model={open=function()return {} end}
function model:request(input,definitions)
    remote.turns=remote.turns+1;save()
    local specs={};for _,d in ipairs(definitions)do specs[d.name]=d end
    assert(specs.cite_source and specs.come_back_later)
    local calls=json.array()
    if remote.turns==1 then
        assert(specs.describe_tool and not specs.report_build.parameters.properties.deeply_specific_field)
        if scenario=="unfold" then calls[#calls+1]=call("describe_tool",{name="report_build"}) end
        if scenario=="defer" or scenario=="wake_unknown" then
            calls[#calls+1]=call("come_back_later",{minutes=17,note=" Check the publication. "})
            calls[#calls+1]=call("device_read",{})
        else
            calls[#calls+1]=call("cite_source",{quote="Measured 7",source="sensor log"})
            if scenario=="lookup" then calls[#calls+1]=call("device_read",{}) end
            if scenario=="queued" then calls[#calls+1]=call("device_send",{}) end
        end
    else
        assert(remote.turns==2)
        if scenario=="unfold" then
            assert(not specs.describe_tool and specs.report_build.parameters.properties.deeply_specific_field,"unfolding was lost across restart")
            local whole=false
            for _,item in ipairs(input)do if item.type=="function_call_output" and item.call_id=="describe_tool" then
                whole=item.output:find("deeply_specific_field",1,true)~=nil
            end end
            assert(whole,"describe did not return its full schema")
        end
    end
    local items=json.array()
    for _,c in ipairs(calls)do items[#items+1]={type="function_call",name=c.name,call_id=c.id,arguments=c.arguments} end
    return {answer="Ready.",items=items,calls=calls,usage={units=10}}
end
local result=Runner.run{config={model={alias="test"}},task={taskId="task",ownerId="person",assigneeId="executor",version=remote.version},client=client,
    history={},model=model,registry=registry,authority=authority,root=root,stateName=scenario,controls=true,
    historyChanged=scenario=="defer" and mode=="recover",
    input=json.array(),role="Role",maxTurns=4,beforeCall=function(c)assert(not Controls.handles(c.name));return true end}
local final
for _,event in pairs(remote.events)do if event.title=="result" then final=event end end
if scenario=="defer" then
    assert(result.outcome=="deferred" and not final and remote.executed==0 and remote.turns==1 and remote.wakes==1)
elseif scenario=="wake_unknown" then
    assert(result.outcome=="wake_outcome_unknown" and not result.resume and not final and remote.wakes==0 and remote.turns==1)
else
    assert(final and remote.turns==2 and result.outcome==(scenario=="queued" and "waiting" or "completed"))
    if scenario=="lookup" then assert(not final.quoted and not final.source and remote.executed==1)
    else assert(final.quoted=="Measured 7" and final.source=="sensor log" and remote.executed==0) end
    assert(final.kind==(scenario=="queued" and "message" or "result"))
end
root:close()
`
	if err := os.WriteFile(entry, []byte(script), 0600); err != nil {
		t.Fatal(err)
	}
	binary, _ := filepath.Abs("../build/agent-lua")
	modules, _ := filepath.Abs("../lua")
	for _, scenario := range []string{"unfold", "lookup", "queued", "defer", "wake_unknown"} {
		if scenario == "unfold" || scenario == "defer" || scenario == "wake_unknown" {
			output, err := exec.Command(binary, entry, modules, directory, scenario, "crash").CombinedOutput()
			if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 73 {
				t.Fatalf("%s did not crash inside its effect: %v %s", scenario, err, output)
			}
		}
		if output, err := exec.Command(binary, entry, modules, directory, scenario, "recover").CombinedOutput(); err != nil {
			t.Fatalf("%s control continuation: %v %s", scenario, err, output)
		}
	}
}
