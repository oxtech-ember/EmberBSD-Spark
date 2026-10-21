package probe

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// The process dies after a paid request or after the server commits a write.
// Restart must settle delivery without asking about the row again.
func TestRowsResumeDeliveryWithoutRepeatingPaidRequests(t *testing.T) {
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	entry := filepath.Join(directory, "rows.lua")
	script := `package.path=arg[1].."/?.lua;"..package.path
local json,fs,Rows=require("json"),require("asenta.fs"),require("rows")
local root=assert(fs.root(arg[2],false))
local scenario,mode=arg[3],arg[4]
local remoteName=scenario.."-server.json"
local remote=root:stat(remoteName) and json.decode(assert(root:read(remoteName))) or {
    version=1,calls=0,charges=0,unknown=0,fills=0,events={},items=json.array({
        {itemId="done",input="Already answered",state="done",answer="Previous"},
        {itemId="row/1",input="Sensor 0133",state="pending"}})}
local function save() assert(root:write(remoteName,json.encode(remote))) end
local function copy(value) local out={};for k,v in pairs(value) do out[k]=v end;return out end
local client={version=remote.version,readUpTo=1}
function client:lease()
    self.version=remote.version
    return {taskId="task",version=self.version}
end
function client:prepare(event)
    local wire=copy(event)
    assert(wire.requestId,"each record requires a stable key")
    wire.version=wire.version or self.version;wire.readUpTo=wire.readUpTo or self.readUpTo
    return wire
end
function client:append(event)
    local previous=remote.events[event.requestId]
    if previous then
        assert(previous.units==event.units and previous.body==event.body)
        self.version=remote.version
        return previous
    end
    assert(event.version==remote.version,"new write silently changed its read version")
    remote.version=remote.version+1
    local answer=copy(event);answer.eventId="event-"..remote.version
    remote.events[event.requestId]=answer
    if event.title=="thinking" then
        assert(remote.fills==0,"last row closed before its charge")
        assert(event.units==100 and event.cachedUnits==20 and event.chargedUnits==60 and event.costMicro==8)
        remote.charges=remote.charges+1
    elseif event.errorCode=="model_outcome_unknown" then
        assert(event.state=="failed" and event.spendUnknown)
        remote.unknown=remote.unknown+1
    else error("unexpected event") end
    save()
    if mode=="charge-crash" then os.exit(73) end
    self.version=remote.version
    return answer
end
function client:request(method,path,value)
    if method=="GET" then assert(path=="/api/v1/tasks/task/items");return {items=remote.items} end
    assert(method=="PUT" and path=="/api/v1/tasks/task/items/row%2F1")
    assert(value.answer=="Stable answer." and value.error=="")
    local item=remote.items[2]
    if item.state=="pending" then
        item.state,item.answer="done",value.answer
        remote.fills=remote.fills+1
        save()
    else assert(item.answer==value.answer,"replayed row changed its answer") end
    if mode=="fill-crash" then os.exit(73) end
    return {}
end
local model={}
function model:request(input,definitions,task)
    remote.calls=remote.calls+1;save()
    assert(remote.calls==1,"a paid row was requested twice")
    assert(#definitions==0 and #input==3 and input[1].content=="Pinned role")
    assert(input[3].content=="Classify\nUse the code\n\nSubject: Sensor 0133" and task.seat=="row-seat")
    if mode=="model-crash" then os.exit(73) end
    return {answer=" Stable answer. ",calls=json.array(),usage={units=100,cachedUnits=20,chargedUnits=60,costMicro=8},modelAlias="row-seat",model="Fixture"}
end
local result=Rows.run{root=root,stateName=scenario,client=client,model=model,
    task={taskId="task",title="Classify",subtitle="Use the code",seat="row-seat"},
    role=mode=="recover" and "Changed role" or "Pinned role",revision="pinned-revision"}
assert(mode=="recover")
local state=require("sequence").unpack(root,json.decode(assert(root:read(scenario..".json"))))
assert(state.mode=="done" and state.data.role=="Pinned role" and state.data.revision=="pinned-revision")
assert(remote.calls==1)
if scenario=="delivery" then
    assert(result.outcome=="rows_filled" and result.filled==1 and remote.charges==1 and remote.fills==1)
else
    assert(result.outcome=="model_outcome_unknown" and result.filled==0)
    assert(remote.unknown==1 and remote.fills==0 and remote.items[2].state=="pending")
end
root:close()
`
	if err := os.WriteFile(entry, []byte(script), 0600); err != nil {
		t.Fatal(err)
	}
	binary, _ := filepath.Abs("../build/agent-lua")
	modules, _ := filepath.Abs("../lua")
	for _, scenario := range []struct {
		name  string
		modes []string
	}{
		{"delivery", []string{"charge-crash", "fill-crash", "recover"}},
		{"paid", []string{"model-crash", "recover", "recover"}},
	} {
		for _, mode := range scenario.modes {
			output, err := exec.Command(binary, entry, modules, directory, scenario.name, mode).CombinedOutput()
			if mode != "recover" {
				if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 73 {
					t.Fatalf("%s/%s did not crash inside the effect: %v %s", scenario.name, mode, err, output)
				}
			} else if err != nil {
				t.Fatalf("%s recovery: %v %s", scenario.name, err, output)
			}
		}
	}
}
