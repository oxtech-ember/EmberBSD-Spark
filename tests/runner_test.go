package probe

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestRunnerRecordsEffectsAndPaidTurns(t *testing.T) {
	f := newFixture(t, "tool")
	f.checkStarts = true
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	entry := filepath.Join(directory, "runner.lua")
	source := `package.path=arg[1].."/?.lua;"..package.path
local json,fs=require("json"),require("asenta.fs")
local Client,Model,Registry,Authority=require("client"),require("model"),require("registry"),require("authority")
local file=assert(io.open(arg[2],"rb"));local config=json.decode(file:read("*a"));file:close()
local client=Client.new(config)
local task=client:lease("task")
local history=client:history()
local registry=Registry.new()
local spec=config.luaTools[1]
registry:add{name=spec.name,class="read",description=spec.description,parameters=spec.parameters,
 invoke=assert(loadfile(spec.file,"t"))()}
local root=assert(fs.root(arg[3],false))
local output=require("runner").run{config=config,task=task,history=history,client=client,
 model=Model.new(config,client),registry=registry,authority=Authority.new(client,task,history,registry),
 root=root,stateName="attempt",role="Answer briefly.",maxTurns=4,
 input=json.array({{role="system",content="Answer briefly."},{role="user",content="Decode 0133."}})}
assert(output.outcome=="completed" and output.answer=="Ready." and output.turns==2)
local state=json.decode(assert(root:read("attempt.json",1048576)))
assert(state.mode=="done" and state.pending==nil)
root:close()
print(json.encode(output))
`
	if err := os.WriteFile(entry, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	binary, _ := filepath.Abs("../build/agent-lua")
	modules, _ := filepath.Abs("../lua")
	cmd := exec.Command(binary, entry, modules, f.config, directory)
	cmd.Env = append(os.Environ(), "PROBE_TOKEN=server-test-key", "PROBE_MODEL_KEY=model-test-key")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("composed runner: %v %s", err, output)
	}
	var report map[string]any
	if err := json.Unmarshal(output, &report); err != nil {
		t.Fatal(err)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.completed || f.calls != 2 || f.modelStarts != 2 || f.paidRecords != 2 {
		t.Fatalf("incomplete effects/accounting: completed=%v calls=%d starts=%d paid=%d", f.completed, f.calls, f.modelStarts, f.paidRecords)
	}
}

// Composition, not a second Authority unit test: these events are interpreted
// by the same recovery reader that sees the server feed on the next attempt.
func TestRunnerApprovalContinuation(t *testing.T) {
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	entry := filepath.Join(directory, "approvals.lua")
	source := `package.path=arg[1].."/?.lua;"..package.path
local json,fs=require("json"),require("asenta.fs")
local Registry,Authority,Runner=require("registry"),require("authority"),require("runner")
local root=assert(fs.root(arg[2],false))
for _,scenario in ipairs({"carry","pending","lapsed","opened"}) do
 local history,executions,openings,before={},0,0,0
 local client={version=1,readUpTo=1,config={}}
 function client:prepare(event,id)
  local wire={};for k,v in pairs(event) do wire[k]=v end
  wire.requestId=wire.requestId or id or "authority";wire.version=wire.version or self.version
  wire.readUpTo=wire.readUpTo or self.readUpTo;return wire
 end
 function client:append(event)
  assert(event.version==self.version)
  if event.action and event.title=="carrying_out" then
   if scenario=="lapsed" then error({status=409,reason="approval_lapsed",message="Approval expired"}) end
   if scenario=="opened" then error({status=409,reason="approval_opened",message="Already started"}) end
   openings=openings+1;assert(openings==1,"approval opened twice")
  elseif event.action and event.phase=="start" then error("a carried action opened again") end
  self.version=self.version+1
  local response=self:prepare(event);response.eventId="e"..self.version
  history[#history+1]=response;return response
 end
 function client:lease() return {taskId="task",version=self.version} end
 local task={taskId="task",assigneeId="agent",ownerId="person"}
 local registry=Registry.new()
 registry:add{name="act",class="physical",description="Act",invoke=function()executions=executions+1;return "acted" end}
 local approval={eventId="approved",kind="confirmation",decision="approved",action='{"tool":"act","args":{"target":"given"}}'}
 if scenario~="pending" then history[1]=approval end
 local authority=Authority.new(client,task,history,registry)
 local turns=0
 local model={open=function()return {} end}
 function model:request()
  turns=turns+1
  local calls=json.array()
  if scenario=="pending" and turns==1 then calls[1]={id="call",name="act",args={target="given"},arguments='{"target":"given"}'} end
  return {answer="Finished.",items=json.array(),calls=calls,usage={units=1}}
 end
 local result=Runner.run{config={model={alias="test"}},task=task,client=client,history=history,
  model=model,registry=registry,authority=authority,root=root,stateName=scenario,maxTurns=3,input=json.array(),
  beforeCall=function()before=before+1;return true end}
 if scenario=="carry" then
  assert(result.outcome=="completed" and executions==1 and openings==1 and before==0)
  local business=false
  for _,e in ipairs(history) do if e.title=="act" and e.causedBy=="approved" and not e.level then business=true end end
  assert(business,"carry result must survive trace pruning")
 elseif scenario=="pending" then
  assert(result.outcome=="waiting" and executions==0)
  for _,e in ipairs(history) do if e.kind=="confirmation" then e.decision="approved" end end
  local resumed=Authority.new(client,task,history,registry):pending()
  assert(#resumed==1,"deferred output was mistaken for execution")
 elseif scenario=="lapsed" then
  assert(executions==0 and #Authority.new(client,task,history,registry):pending()==0)
 else
  assert(executions==0)
  local asked=false;for _,e in ipairs(history) do if e.kind=="question" then asked=true end end
  assert(asked,"opened action needs an explicit recorded unknown outcome")
 end
end
root:close()
`
	if err := os.WriteFile(entry, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	binary, _ := filepath.Abs("../build/agent-lua")
	modules, _ := filepath.Abs("../lua")
	if out, err := exec.Command(binary, entry, modules, directory).CombinedOutput(); err != nil {
		t.Fatalf("approval continuation: %v %s", err, out)
	}
}

func TestApplicationComposesInstalledModules(t *testing.T) {
	f := newFixture(t, "answer")
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	binary, _ := filepath.Abs("../build/agent-lua")
	entry, _ := filepath.Abs("../lua/run.lua")
	cmd := exec.Command(binary, entry, f.config, "task", directory)
	cmd.Env = append(os.Environ(), "PROBE_TOKEN=server-test-key", "PROBE_MODEL_KEY=model-test-key")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("application: %v %s", err, out)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.completed || f.turns != 1 {
		t.Fatalf("application did not finish: %+v", f)
	}
}

func TestRunnerControlsStopActionsAndUpdateSkills(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	entry := filepath.Join(dir, "control-runner.lua")
	source := `package.path=arg[1].."/?.lua;"..package.path
local json,fs,Runner,Registry=require("json"),require("asenta.fs"),require("runner"),require("registry")
local root=assert(fs.root(arg[2],false))
for _,scenario in ipairs({"question","skill"}) do
 local task={taskId="task",ownerId="person",assigneeId="agent"}
 local client={version=1,readUpTo=1}
 local events,applied,turns={},false,0
 function client:prepare(e,id)
  local out={};for k,v in pairs(e)do out[k]=v end
  out.version,out.readUpTo,out.requestId=out.version or self.version,out.readUpTo or self.readUpTo,out.requestId or id
  return out
 end
 function client:append(e)
  assert(e.version==self.version);self.version=self.version+1
  e.eventId="e"..self.version;events[#events+1]=e;return e
 end
 function client:lease()return task end
 function client:request(method,path,body)
  assert(method=="PUT" and path=="/api/v1/tasks/task/skills" and body.skills[1]=="diagnostic")
  self.version=self.version+1;task.version=self.version;task.skills=body.skills;return {task=task}
 end
 local registry=Registry.new()
 registry:add{name="unsafe",class="physical",invoke=function()error("ran a call after a question")end}
 local model={open=function()return {} end}
 function model:request(input,definitions)
  turns=turns+1
  local calls=json.array()
  if turns==1 then
   if scenario=="question" then calls=json.array({{name="ask_human",id="q",args={question="Which sensor?",note="The logs name two sensors."}},
    {name="unsafe",id="later",args={}}})
   else calls[1]={name="use_skill",id="choose",args={skills={"diagnostic"}}} end
  elseif scenario=="skill" then
   assert(applied)
   local declared=false
   for _,definition in ipairs(definitions)do assert(definition.name~="use_skill");if definition.name=="skill_read" then declared=true end end
   assert(declared,"chosen skill was not offered to next model turn")
  end
  return {items=json.array(),calls=calls,answer="Ready",usage={units=1}}
 end
 local result=Runner.run{config={model={alias="test"}},task=task,client=client,model=model,registry=registry,
  root=root,stateName=scenario,input=json.array(),history={},maxTurns=3,controls=true,
  controlContext={pinned=true,catalogue={{name="diagnostic",summary="Sensor diagnostic",text="Read the sensor."}}},
  onSkills=function(plan)
   applied=true;assert(plan.skills[1].name=="diagnostic")
   registry:add{name="skill.read",class="read",invoke=function()return "value" end}
  end}
 if scenario=="question" then
  assert(result.outcome=="waiting" and turns==1)
  local question,aside=false,false
  for _,e in ipairs(events)do if e.kind=="question" then question=true elseif e.title=="set_aside" then aside=true end end
  assert(question and aside)
 else assert(result.outcome=="completed" and turns==2 and applied) end
end
root:close()
`
	if err := os.WriteFile(entry, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	binary, _ := filepath.Abs("../build/agent-lua")
	modules, _ := filepath.Abs("../lua")
	if out, err := exec.Command(binary, entry, modules, dir).CombinedOutput(); err != nil {
		t.Fatalf("composed control calls: %v %s", err, out)
	}
}

func TestRunnerSettlesPaidUsageBeforeReadingNewInput(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	entry := filepath.Join(dir, "boundary.lua")
	source := `package.path=arg[1].."/?.lua;"..package.path
local json,fs,Runner,Registry=require("json"),require("asenta.fs"),require("runner"),require("registry")
local root=assert(fs.root(arg[2],false))
local version=1
local client={version=1,readUpTo=7}
function client:prepare(e,id)
 local out={};for k,v in pairs(e)do out[k]=v end
 out.version,out.readUpTo,out.requestId=out.version or self.version,out.readUpTo or self.readUpTo,out.requestId or id
 return out
end
local paid,modelCalls=0,0
function client:append(e)
 if e.units==12 and version<50 then version=50;error({status=409,reason="changed_meanwhile",message="A person added a correction"}) end
 assert(e.version==version,"stale write")
 if e.units==12 then assert(e.readUpTo==7,"unseen correction was acknowledged as read");paid=paid+1 end
 version=version+1;self.version=version;e.eventId="e"..version;return e
end
function client:lease()self.version=version;return {taskId="task",version=version}end
local task={taskId="task",version=1,ownerId="person"}
local model={open=function()return {} end,request=function()
 modelCalls=modelCalls+1
 return {answer="Old answer",items=json.array(),calls=json.array(),usage={units=12}}
end}
local args={task=task,config={model={alias="test"}},client=client,root=root,stateName="attempt",input=json.array(),
 history={},registry=Registry.new(),model=model,maxTurns=3}
local first=Runner.run(args)
assert(first.resume and first.reason=="changed_meanwhile" and modelCalls==1 and paid==0)
args.task={taskId="task",version=50,ownerId="person"};args.historyChanged=true
client.version,client.readUpTo=50,99
local second=Runner.run(args)
assert(second.outcome=="superseded" and second.resume and paid==1 and modelCalls==1)
root:close()
`
	if err := os.WriteFile(entry, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	binary, _ := filepath.Abs("../build/agent-lua")
	modules, _ := filepath.Abs("../lua")
	if out, err := exec.Command(binary, entry, modules, dir).CombinedOutput(); err != nil {
		t.Fatalf("read boundary recovery: %v %s", err, out)
	}
}
