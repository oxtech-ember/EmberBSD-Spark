package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestAuthorityKeepsApprovedActionAtMostOnce(t *testing.T) {
	script := `
package.path = arg[1] .. "/?.lua;" .. package.path
local json, Registry, Authority = require("json"), require("registry"), require("authority")
local registry = Registry.new()
registry:add{name="mail.send", class="external", invoke=function() error("gate must not invoke") end}
registry:add{name="files.read", class="read", foreign=true, source="files", invoke=function() end}
local client = {readBound={"example.org"}}
function client:prepare(event)
    event.version, event.readUpTo = 7, 42
    return event
end
local task = {taskId="task", ownerId="person", assigneeId="executor"}
local foreign = {eventId="old-answer", kind="message", level="trace", title="files.read", body="A document"}
local call = {id="call-1", name="mail_send", args={to="owner@example.org", text="Ready"}}
local function gate(history) return Authority.new(client, task, history, registry) end
local function confirm(entry, id, verdict)
    local event = json.decode(json.encode(entry))
    event.eventId, event.guard = id, verdict
    event.decision = verdict == "pass" and "approved" or "denied"
    return event
end

local authority = gate({foreign})
local queued = authority:decide(call, {stepId="step"})
assert(queued.status == "defer" and queued.event.kind == "confirmation")
assert(queued.event.title == "mail.send" and queued.event.risk == "external")
assert(queued.event.requestId == "step/call-1/queue" and queued.event.version == 7 and queued.event.readUpTo == 42)
local action = json.decode(queued.event.action)
assert(action.tool == "mail_send" and action.foreignText, "old foreign text lost its mark")
local approval = confirm(queued.event, "approved", "pass")
local accepted = authority:decide(call, {stepId="step", event=approval})
assert(accepted.status == "execute" and accepted.causedBy == "approved" and accepted.approvedAction == approval.action)

-- A state change and the guard's own accounting are not tool execution.
local moved = {eventId="moved", kind="state_change", causedBy="approved", body="input_required"}
local price = {eventId="price", kind="message", level="trace", title="action_guard", causedBy="approved"}
authority = gate({foreign, approval, moved, price})
local pending = authority:pending()
assert(#pending == 1 and pending[1].call.args.text == "Ready")
local intent = authority:decide(pending[1].call, pending[1])
assert(intent.reason == "open_approval" and intent.event.title == "carrying_out")
assert(intent.event.requestId == "approved/carrying@price" and intent.event.action == approval.action)
intent.event.eventId = "intent"
pending[1].event = intent.event
accepted = authority:decide(pending[1].call, pending[1])
assert(accepted.status == "execute" and accepted.approvedAction == approval.action)

-- A restart after the recorded intent never executes the action again.
authority = gate({foreign, approval, moved, price, intent.event})
pending = authority:pending()
local unknown = authority:decide(pending[1].call, pending[1])
assert(unknown.status == "defer" and unknown.event.kind == "question" and unknown.event.requestId == "approved/unknown")
unknown.event.eventId = "question"
pending[1].event = unknown.event
assert(authority:decide(pending[1].call, pending[1]).event == nil and #authority:pending() == 0)
local ended = {eventId="answer", kind="message", level="trace", title="mail.send", causedBy="approved", body="Sent"}
assert(#gate({approval, ended}):pending() == 0, "immediate guard-approved result was repeated")
local pruned = gate({approval})
local due = pruned:pending()[1]
due.error = {reason="approval_opened", message="already opened"}
assert(pruned:decide(due.call, due).event.requestId == "approved/unknown", "server duplicate-start refusal was ignored")

-- A block is explicit, escalation retains its exact payload, hard deny has no road.
authority = gate({})
queued = authority:decide(call, {stepId="blocked-step"})
local blocked = confirm(queued.event, "blocked", "block")
blocked.guardReason = "Use another recipient"
local refused = authority:decide(call, {stepId="blocked-step", event=blocked})
assert(refused.status == "refused" and refused.blockedId == "blocked" and not refused.event)
assert(authority:decide(call, {stepId="repeat"}).event == nil)
authority:observe(foreign)
local escalation = authority:escalate("blocked", "No other path", {stepId="step", callId="escalate-1"})
assert(escalation.event.escalate and escalation.event.action == blocked.action, "escalation changed the approved subject")
authority = gate({})
local hard = confirm(queued.event, "hard", "hard_deny")
refused = authority:decide(call, {stepId="step", event=hard})
assert(refused.status == "refused" and not refused.blockedId and not authority:escalate("hard", "Try", {}).event)
local unavailable = confirm(queued.event, "unavailable", "unavailable")
unavailable.decision = ""
assert(gate({}):decide(call, {stepId="step", event=unavailable}).status == "defer")
assert(gate({}):decide({name="files_read", args={url="https://sub.example.org/report"}}, {}).status == "execute")
assert(gate({}):decide({name="files_read", args={url="https://elsewhere.test/report"}}, {}).status == "refused")
`
	file := filepath.Join(t.TempDir(), "authority.lua")
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
		t.Fatalf("action authority contract failed: %v\n%s", err, output)
	}
}
