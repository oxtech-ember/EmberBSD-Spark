package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestContextRetainsEvidenceAndAccountsForCompaction(t *testing.T) {
	script := `
package.path = arg[1] .. "/?.lua;" .. package.path
local json, Registry, Context = require("json"), require("registry"), require("context")
local registry = Registry.new()
registry:add{name="diagnostic.read", class="read", foreign=true, invoke=function() end}
local task = {taskId="task", title="Diagnose the sensor", assigneeId="executor"}
local options = {role="Role", facts="Facts", notebook="Notebook", skills="Skills", registry=registry, actorId="executor"}
local history = {
    {eventId="first", actorId="person", kind="message", body="Old literal material"},
    {eventId="fold", actorId="executor", kind="message", level="trace", title="fold", quoted="first", body="Earlier diagnostic request"},
    {eventId="read", actorId="executor", kind="message", level="trace", title="diagnostic.read", quoted='{"channel":3}', body="Sensor 123456 measured 0.62"},
    {eventId="start", actorId="executor", kind="message", level="trace", phase="start", title="diagnostic.read", body="Not an answer"},
    {eventId="question", actorId="executor", kind="question", body="Which channel?"},
    {eventId="answer", actorId="person", kind="message", inReplyTo="question", body="Channel three"},
    {eventId="attachment", actorId="person", kind="attachment", source="file-1", body="wiring.pdf"}}
local prepared = Context.prepare(task, history, options)
assert(prepared.foreign, "folded history cleared foreign provenance")
assert(prepared.input[1].content == "Role" and prepared.input[2].content == "Facts")
assert(prepared.input[3].content == "Notebook" and prepared.input[4].content == "Skills")
local recalled, asked, all = nil, nil, ""
for i, item in ipairs(prepared.input) do
    all = all .. item.content .. "\n"
    if item.content:find("[CONTENT_LOST]", 1, true) then recalled = i end
    if item.content == "Which channel?" then asked = i end
end
assert(recalled and asked and recalled < asked and all:find("Sensor 123456", 1, true))
assert(not all:find("Old literal material", 1, true) and not all:find("Not an answer", 1, true))
assert(all:find("[FOLDED]", 1, true) and all:find("file-1", 1, true) and all:find("not been loaded", 1, true))
assert(all:find("The person answered the question Which channel?: Channel three", 1, true))

-- A provider fact anchors later estimates; an unknown window invents no cap.
local definitions = registry:definitions()
local estimate = Context.measure(prepared, definitions, {contextWindow=0}, 100)
assert(estimate.fits)
Context.counted(prepared, 900)
assert(Context.measure(prepared, definitions, {contextWindow=1000}, 100).fits == false)
local ascii = {input={{role="user", content=string.rep("x", 30)}}, window={}}
local wide = {input={{role="user", content=string.rep(utf8.char(0x4e00), 30)}}, window={}}
assert(Context.measure(ascii).occupied == Context.measure(wide).occupied, "window estimate counted UTF-8 bytes as characters")

-- Only an old, already-seen output is offered to the paid compactor.
local original = "Sensor 123456: " .. string.rep("measured data ", 300)
local state = {input=json.array({{role="system", content="Role"},
    {type="function_call", name="diagnostic_read", call_id="old", arguments='{"channel":3}'},
    {type="function_call_output", call_id="old", output=original},
    {type="function_call", name="diagnostic_read", call_id="recent", arguments="{}"},
    {type="function_call_output", call_id="recent", output=string.rep("r", 500)},
    {type="function_call", name="diagnostic_read", call_id="unseen", arguments="{}"},
    {type="function_call_output", call_id="unseen", output=string.rep("u", 5000)}}),
    settled={}, recorded={old="record-old"}, window={}, sent=5, foreign=true}
local job = Context.compact(state, {model={compactor="cheap", compactCeilingTokens=1000}, registry=registry})
assert(job and job.index == 3 and job.alias == "cheap" and job.input[1].role == "user")
assert(not job.input[1].content:find("[CONTENT_LOST]", 1, true))
local nextState, event = Context.complete(state, job, {answer="The sensor was measured.", modelAlias="cheap",
    usage={units=100, cachedUnits=20, chargedUnits=90, costMicro=17, spendUnknown=false}})
assert(state.input[3].output == original, "uncommitted compaction replaced the working input")
assert(nextState.input[3].output:find("[CONTENT_LOST]", 1, true) and nextState.input[3].output:find("123456", 1, true))
assert(nextState.input[5].output == state.input[5].output and nextState.input[7].output == state.input[7].output)
assert(event.title == "compaction" and event.units == 100 and event.chargedUnits == 90 and event.costMicro == 17)
assert(event.imprint.digests[1].of == "record-old" and #event.imprint.digests[1].original == 64 and nextState.foreign)
local rejected, paid = Context.complete(state, job, {reason="model_incomplete", usage={units=35}, message="cut"})
assert(rejected.input[3].output == original and rejected.settled["3"] and paid.units == 35)

local long = {}
for i = 1, 7 do long[i] = {eventId="line-" .. i, kind="message", actorId="person", body=string.rep("facts ", 2000)} end
local fold = Context.planFold(task, long, {model={compactor="cheap"}, actorId="executor"})
assert(fold and fold.upTo == "line-6")
local _, refused = Context.complete(prepared, fold, {reason="model_incomplete", usage={units=12}})
assert(refused.title == "fold_refused" and not refused.quoted and refused.units == 12)
`
	file := filepath.Join(t.TempDir(), "context.lua")
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
		t.Fatalf("context and compaction contract failed: %v\n%s", err, output)
	}
}
