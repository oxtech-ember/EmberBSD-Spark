package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestFailureSeriesAndGatewayPlan(t *testing.T) {
	directory := t.TempDir()
	script := filepath.Join(directory, "failures.lua")
	if err := os.WriteFile(script, []byte(`package.path=arg[1] .. "/?.lua;" .. package.path
local Failures,json=require("failures"),require("json")
local task={taskId="task-one",state="working"}
local context={stepId="step-one",woke="human-one",causedBy="cause-one",modelAlias="main",model="model-one"}
local history={{eventId="human-one",kind="message",body="Do the work"}}
local cause={message="The connection broke"}
local keys={}
for attempt=1,3 do
    history[#history+1]={eventId="entry-" .. attempt,kind="message",title="attempt_entered"}
    history[#history+1]={eventId="conditions-" .. attempt,kind="message",title="conditions_read"}
    history[#history+1]={eventId="start-" .. attempt,kind="message",title="thinking",phase="start"}
    local saved=json.decode(json.encode(history))
    local plan=Failures.plan(saved,task,cause,context)
    assert(plan.code == "runner" and plan.attempt == attempt and plan.gaveUp == (attempt == 3))
    assert(plan.event.requestId == "task-one/fail/human-one/" .. attempt)
    assert(plan.event.errorCode == "runner" and plan.event.modelAlias == "main" and plan.event.model == "model-one")
    assert(plan.event.kind == "failure" and plan.event.title == "failed")
    if attempt < 3 then assert(plan.outcome == nil and plan.event.level == "trace" and plan.event.state == nil)
    else assert(plan.outcome == "failed" and plan.event.level == nil and plan.event.state == "failed") end
    -- Redelivery of the same durable failure plan is the same write.
    assert(json.encode(Failures.plan(saved,task,cause,context)) == json.encode(plan))
    assert(not keys[plan.event.requestId]);keys[plan.event.requestId]=true
    local event=plan.event;event.eventId="failure-" .. attempt;history[#history+1]=event
end
local opened,count=Failures.series(history)
assert(opened == "human-one" and count == 3)
history[#history+1]={eventId="completed-turn",kind="message",title="thinking",body="Progress"}
local next=Failures.plan(history,task,cause,context)
assert(next.attempt == 1 and next.event.requestId == "task-one/fail/completed-turn/1")
assert(not keys[next.event.requestId])
assert(Failures.plan({},task,cause,context).event.requestId == "task-one/fail/1")
-- Only account/day limits from the model gateway trigger a wake.
local limit=Failures.plan(history,task,{status=402,message="Insufficient credits",gateway=true},context)
assert(limit.code == "gateway_limit" and limit.outcome == "deferred" and not limit.gaveUp)
assert(limit.event.kind == "message" and limit.event.level == "trace" and limit.event.state == nil)
assert(limit.event.title == "gateway_limit" and limit.event.errorCode == "gateway_limit")
assert(limit.event.requestId == "task-one/step-one/gateway-limit" and limit.wake.afterSeconds == 1800)
for _,status in ipairs({400,429,500}) do
    local daily=Failures.plan(history,task,{status=status,message="DAY TOKEN LIMIT of 4000000 reached",gateway=true},context)
    assert(daily.wake.afterSeconds == 1800)
end
assert(Failures.plan(history,task,{status=429,message="Slow down",gateway=true},context).code == "runner")
assert(Failures.plan(history,task,{status=402,message="Another HTTP service"},context).code == "runner")
assert(Failures.plan(history,task,{status=402,reason="spend_unknown",message="Our ledger",gateway=true},context).code == "runner")
local two={{eventId="asked",kind="message"},{kind="failure",title="failed"},{kind="failure",title="failed"}}
local fallback=Failures.plan(two,task,{reason="gateway_limit",message="Daily limit"},{stepId="fixed",wakeFailed=true})
assert(fallback.gaveUp and fallback.code == "runner" and fallback.wake == nil and fallback.event.state == "failed")
local secret="sk-" .. string.rep("x",32)
local mutator=Failures.plan(history,task,{reason="mutator_broken",message="hook: " .. secret .. " " .. string.rep("detail",110)},context)
assert(mutator.outcome == "mutator_broken" and mutator.gaveUp and mutator.event.title == "mutator_broken")
assert(mutator.event.state == "failed" and mutator.event.level == nil and mutator.event.errorCode == "mutator_broken")
assert(mutator.event.causedBy == "cause-one" and mutator.event.requestId == "task-one/human-one/mutator-broken")
assert(#mutator.event.errorDetail == 500 and not json.encode(mutator):find(secret,1,true))
local ordinary=Failures.plan({},task,{message="Connection failed with " .. secret,rawBody=secret,headers=secret},context)
assert(ordinary.event.errorDetail:find("[SECRET_HIDDEN]",1,true) and not json.encode(ordinary):find(secret,1,true))
for reason,outcome in pairs({task_canceled="canceled",changed_meanwhile="stale",lease_taken="lease_lost",asleep="deferred"}) do
    local quiet=Failures.plan(history,task,{reason=reason,message=secret,headers=secret},context)
    assert(quiet.outcome == outcome and quiet.event == nil and quiet.wake == nil and not json.encode(quiet):find(secret,1,true))
end
assert(Failures.plan(history,{taskId="task-one",state="canceled"},cause,context).outcome == "canceled")
`), 0600); err != nil {
		t.Fatal(err)
	}
	binary, err := filepath.Abs("../build/agent-lua")
	if err != nil {
		t.Fatal(err)
	}
	modules, err := filepath.Abs("../lua")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, script, modules)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("failure plan contract failed: %v\n%s", err, output)
	}
}
