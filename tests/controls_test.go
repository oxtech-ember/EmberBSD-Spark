package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestControlsStopOneReplyAndResumeSkillSelection(t *testing.T) {
	script := `
package.path = arg[1] .. "/?.lua;" .. package.path
local json, Controls, Registry, Authority = require("json"), require("controls"), require("registry"), require("authority")
local task = {taskId="sensor/task", ownerId="owner", assigneeId="executor"}
local registry = Registry.new()
registry:add{name="device.send", class="external", invoke=function() error("no action may follow a question") end}
local calls = {
    {id="q1",name="ask_human",args={question="Which sensor?",note="The log is read; the sensor identifier is missing.",who={"absent"}}},
    {id="send",name="device_send",args={command="start"}},
    {id="q2",name="ask_human",args={question="Which day?"}},
    {id="q3",name="ask_human",args={question="Which channel?"}},
    {id="q4",name="ask_human",args={question="Which range?"}}}
local ctx = {task=task,history={},stepId="step",causedBy="thinking",state={},calls=calls,index=1,registry=registry}
local plan = Controls.decide(calls[1],ctx)
assert(plan.outcome == "waiting" and plan.consumeRest)
assert(plan.events[1].title == "handover" and plan.events[1].requestId == "step/handover")
local questions = 0
for _,event in ipairs(plan.events) do
    if event.kind == "question" then
        questions=questions+1
        assert(event.state == "input_required" and event.stepId == "step" and event.addresseeIds[1] == "owner")
    end
end
assert(questions == 3 and plan.events[#plan.events].title == "set_aside")
assert(plan.events[#plan.events].body:find("device.send",1,true))
local retry=Controls.decide(calls[1],ctx)
assert(#retry.events == #plan.events)
for i,event in ipairs(plan.events) do assert(retry.events[i].requestId == event.requestId, "replanning changed delivery identities") end
assert(next(ctx.state) == nil, "control mutated its caller's checkpoint")

-- The persisted reminder survives restart; a second forbidden question honestly fails.
task.asking="never"
local first=Controls.decide(calls[1],ctx)
assert(first.state.toldNotToAsk and #first.events == 0 and not first.outcome)
ctx.state=json.decode(json.encode(first.state))
local second=Controls.decide(calls[1],ctx)
assert(second.outcome == "gave_up" and second.events[1].errorDetail == "not_asked")
local refused=Controls.decide({id="cannot",name="cannot_do",args={reason="No equipment driver",class="not_asked"}},ctx)
assert(refused.events[1].errorDetail == "other" and refused.events[1].requestId == "step/cannot")

-- Escalation preserves the exact blocked action and continues independent work.
local client={prepare=function(_,entry) return entry end}
ctx.authority=Authority.new(client,task,{},registry)
local queued=ctx.authority:decide(calls[2],{stepId="step"})
local blocked=json.decode(json.encode(queued.event))
blocked.eventId,blocked.guard,blocked.decision="blocked","block","denied"
ctx.authority:decide(calls[2],{stepId="step",event=blocked})
local escalation={id="escalate",name="escalate_action",args={id="blocked",why="There is no read-only path."}}
local escalated=Controls.decide(escalation,ctx)
assert(not escalated.outcome and escalated.continuation == "escalate_action")
assert(escalated.events[1].action == blocked.action and escalated.events[1].causedBy == "blocked")
ctx.event=json.decode(json.encode(escalated.events[1]));ctx.event.eventId="person-approval"
local delivered=Controls.decide(escalation,ctx)
assert(delivered.queued and #delivered.events == 0 and not delivered.outcome)
ctx.event=nil

-- The one-time mutation is never replayed; full pinned instructions are applied only after acknowledgement.
ctx.catalogue={{name="sensors",summary="Diagnose sensor failures. More detail.",text="Read the channel before changing it.",tools={},files={}}}
ctx.state={}
local choice=Controls.decide({id="choose",name="use_skill",args={skills={" Sensors "}}},ctx)
assert(choice.effect.replay == "never" and choice.effect.input.method == "PUT")
assert(choice.effect.input.path == "/api/v1/tasks/sensor%2Ftask/skills" and choice.names[1] == "sensors")
ctx.pinned=true
local chosen=Controls.complete(choice,{task={taskId=task.taskId,version=8,skills={"sensors"}}},ctx)
assert(chosen.refreshSkills and chosen.task.version == 8 and chosen.state.skillChoiceClosed)
assert(chosen.skills[1] == ctx.catalogue[1] and chosen.output:find(ctx.catalogue[1].text,1,true))
ctx.state=chosen.state
assert(not Controls.choiceOpen(ctx))
for _,definition in ipairs(Controls.definitions(ctx)) do assert(definition.name ~= "use_skill") end
ctx.pinned=false
local loading=Controls.complete(choice,{task=chosen.task},ctx)
assert(loading.effect.replay == "safe" and loading.effect.input.method == "GET")
assert(Controls.complete(loading,{skills=ctx.catalogue},ctx).refreshSkills)
local lost=Controls.complete(choice,{error={message="connection closed"}},ctx)
assert(lost.fatal and not lost.state.skillChoiceClosed, "unknown selection was claimed not to have happened")
`
	file := filepath.Join(t.TempDir(), "controls.lua")
	if err := os.WriteFile(file, []byte(script), 0600); err != nil {
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
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if output, err := exec.CommandContext(ctx, binary, file, modules).CombinedOutput(); err != nil {
		t.Fatalf("control outcome contract failed: %v\n%s", err, output)
	}
}
