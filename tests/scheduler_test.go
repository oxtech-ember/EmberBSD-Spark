package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestSchedulerStreamsQueueAndDoesNotRepeatPaidAttempts(t *testing.T) {
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(directory, "scheduler.lua")
	if err := os.WriteFile(script, []byte(schedulerScenario), 0600); err != nil {
		t.Fatal(err)
	}
	modules, err := filepath.Abs("../lua")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if output, err := exec.CommandContext(ctx, "../build/agent-lua", script, directory, modules).CombinedOutput(); err != nil {
		t.Fatalf("scheduler queue and durable attempts: %v\n%s", err, output)
	}
}

const schedulerScenario = `
package.path = arg[2] .. "/?.lua;" .. package.path
local json,fs,Scheduler=require("json"),require("asenta.fs"),require("scheduler")
local root=assert(fs.root(arg[1],false))
local queue=json.array({
  {taskId="unreadable",assigneeId="agent",state="working",version=1,kind="errand"},
  {taskId="ready",assigneeId="agent",state="submitted",version=1,kind="errand"},
  {taskId="unknown",assigneeId="agent",state="working",version=1,kind="errand"},
  {taskId="sleeping",assigneeId="agent",state="working",version=1,kind="errand"},
  {taskId="denied",assigneeId="agent",state="working",version=1,kind="errand"},
  {taskId="delivery",assigneeId="agent",state="working",version=1,kind="errand"},
  {taskId="rows",assigneeId="agent",state="submitted",version=1,kind="run"},
  {taskId="other",assigneeId="someone-else",state="working",version=1},
  {taskId="unassigned",assigneeId="",state="submitted",version=1},
  {taskId="canceled",assigneeId="agent",state="canceled",version=1},
  {taskId="input",assigneeId="agent",state="input_required",version=1}
})
-- The queue is larger than the old held-body limit; foreign tasks are decoded
-- and discarded one at a time. A quoted closing brace crosses chunk boundaries.
for n=1,100 do queue[#queue+1]={taskId="foreign-" .. n,assigneeId="other",state="working",version=1,
  title=string.rep('source } " words ',100)} end
local client={reports=0,reads=0}
function client:request(method,path,value,model,options)
  assert(not model)
  if path=="/api/v1/me/tools" then
    assert(method=="PUT" and type(value.servers)=="table" and value.researchSeats==1)
    assert(#value.available==1 and value.available[1].alias=="spare")
    assert(value.available[1].env[1].name=="EXAMPLE_KEY" and value.available[1].env[1].value==nil)
    self.reports=self.reports+1
    return {},200
  end
  assert(method=="GET" and path=="/api/v1/tasks?state=submitted&state=working")
  assert(options.maxBytes==32*1024*1024 and type(options.consume)=="function")
  self.reads=self.reads+1
  local body=json.encode({tasks=queue})
  assert(#body>131072)
  if self.truncate then body=body:sub(1,-3) end
  for at=1,#body,113 do options.consume(body:sub(at,at+112)) end
  return {},200
end
local calls,statuses,paid={}, {},0
local app={actor="agent",root=root,client=client,config={server={pollMs=17}},
  connections={{report=function() return {alias="connected",connected=true,tools=1} end}},
  passports={{alias="connected"},{alias="spare",name="spare",env={{name="EXAMPLE_KEY",required=true,value="private"}}}}}
local function find(id) for _,task in ipairs(queue) do if task.taskId==id then return task end end end
function app:status(id)
  if id=="unreadable" then error("attempt storage unavailable") end
  return statuses[id]
end
function app:run(id)
  assert(id~="other" and id~="unassigned" and id~="canceled" and id~="input" and id~="rows","unassigned or unsupported work was executed")
  calls[id]=(calls[id] or 0)+1
  local task=find(id)
  if id=="sleeping" and calls[id]<3 then error({status=409,reason="asleep"}) end
  if id=="denied" then error({status=403,reason="not_entrusted"}) end
  if id=="delivery" and calls[id]==1 then
    statuses[id]={mode="waiting",replay="delivery",pendingKind="append",version=task.version,attemptId=id}
    return {outcome="waiting",resume=true,version=task.version}
  end
  paid=paid+1
  task.version=task.version+1
  if id=="unknown" then
    statuses[id]={mode="parked",certainty="unknown",outcome="unknown_model_outcome",version=task.version,attemptId=id}
    return {outcome="unknown_model_outcome",resume=false,version=task.version}
  end
  task.state="completed"
  statuses[id]={mode="done",outcome="completed",version=task.version,attemptId=id}
  return {outcome="completed",version=task.version}
end
statuses.sleeping={mode="done",outcome="deferred",version=1,attemptId="before-sleep"}
local service=Scheduler.new(app)
service:sweep()
assert(paid==2 and calls.unknown==1 and calls.sleeping==1 and calls.denied==1 and calls.delivery==1)
assert(calls.rows==nil and calls.unreadable==nil and client.reports==1)
service:sweep()
assert(paid==3 and calls.unknown==1 and calls.sleeping==2 and calls.denied==1 and calls.delivery==2)
service:close()
service=Scheduler.new(app)
service:sweep()
assert(paid==4 and calls.unknown==1 and calls.sleeping==3,"restart repeated a paid unknown attempt or lost the wake")
-- Lease refusals are process-local, as in Go: permissions may have changed
-- without a task version change while the process was stopped.
assert(calls.denied==2)
find("denied").version=2
service:sweep()
assert(calls.denied==3 and paid==4)
find("unknown").version=3
service:sweep()
assert(calls.unknown==2 and paid==5,"new task input did not release the completed scheduling decision")
-- A crash after the runner completed but before the scheduler checkpoint must
-- not turn a finished durable attempt into a fresh model call.
local completed={taskId="post-crash",assigneeId="agent",state="working",version=7}
queue[#queue+1]=completed
statuses[completed.taskId]={mode="done",outcome="waiting",version=7,attemptId="finished"}
service.state.tasks[completed.taskId]={mode="running",version=6}
service:_save()
service:close()
service=Scheduler.new(app)
service:sweep()
assert(not calls[completed.taskId] and paid==5)
-- Superseding an attempt preserves its old read boundary. Even if its final
-- bookkeeping sees the new task version, the next sweep must take that input.
queue[#queue+1]={taskId="superseded",assigneeId="agent",state="working",version=9}
statuses.superseded={mode="done",outcome="superseded",version=9,attemptId="previous"}
service.state.tasks.superseded={mode="waiting",version=9,attemptId="previous"}
service:sweep()
assert(calls.superseded==1 and paid==6)
statuses[completed.taskId].outcome="retry"
service:sweep()
assert(calls[completed.taskId]==1 and paid==7,"a bounded runner retry was suppressed by its completed checkpoint")
client.truncate=true
assert(not pcall(service.sweep,service) and paid==7,"partial queue was executed")
client.truncate=false
local slept
service.sleep=function(ms) slept=ms;service:stop() end
service:run(false)
assert(slept==17 and paid==7)
service:close();root:close()
`
