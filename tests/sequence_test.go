package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestSequenceCopiesReferencesAndPreservesJSON(t *testing.T) {
	script := `package.path=arg[1].."/?.lua;"..package.path
local fs,json,Sequence,Runtime=require("asenta.fs"),require("json"),require("sequence"),require("runtime")
local disk=assert(fs.root(arg[2],false))
local reads,writes=0,0
local root={}
function root:stat(...) return disk:stat(...) end
function root:lock(...) return disk:lock(...) end
function root:read(path,...) if path:match("^sequences/") then reads=reads+1 end;return disk:read(path,...) end
function root:write(path,...) if path:match("^sequences/") then writes=writes+1 end;return disk:write(path,...) end
local input=Sequence.new(root)
input[1]={role="user",content="Original evidence",empty=json.array(),absent=json.null}
input[2]={type="function_call_output",call_id="read-1",output="Original result"}
local fork=Sequence.copy(input)
local refs=Sequence.references(fork);refs[1]=nil
assert(#input==2 and #fork==2 and reads==0 and writes==2,"copy loaded or rewrote item text")
assert(disk:read("sequences/"..Sequence.references(input)[1]..".json")==
    '{"absent":null,"content":"Original evidence","empty":[],"role":"user"}',"item keys are not canonical")
local packed=Sequence.pack({input=input,pending={input={messages=fork}}})
assert(reads==0 and packed.input.__asenta_sequence==1 and #packed.input.refs==2)
local restored=Sequence.unpack(root,json.decode(json.encode(packed)))
assert(Sequence.is(restored.input) and reads==0,"restoring refs loaded the transcript")
local changed=fork[2];changed.output="Revised result";fork[2]=changed
assert(input[2].output=="Original result" and fork[2].output=="Revised result")
assert(writes==3,"replacement rewrote a shared item")
fork[3]=input[1]
assert(writes==3,"an identical item was written twice")
local empty=Sequence.empty_like(input)
assert(Sequence.is(empty) and #empty==0 and json.encode(empty)=="[]")
-- Native history reaches Runner's structural redaction before checkpointing.
-- Copying only the proxy metatable loses the backing store and used to fail.
local secrets=require("secrets")
local readings=Sequence.new(root)
readings[1]={note="sk-"..string.rep("a",32),value=42,unknown=json.null,empty=json.array()}
local clean,hidden=secrets.value({readings=readings})
assert(hidden==1 and Sequence.is(clean.readings) and #clean.readings==1)
assert(clean.readings[1].note==secrets.mark and readings[1].note~=secrets.mark)
assert(clean.readings[1].value==42 and clean.readings[1].unknown==json.null)
assert(json.encode(clean.readings[1].empty)=="[]")
local checkpoint=Sequence.unpack(root,json.decode(json.encode(Sequence.pack(clean))))
assert(checkpoint.readings[1].note==secrets.mark)
local ordinary=Sequence.empty_like({});assert(not Sequence.is(ordinary) and next(ordinary)==nil)
local encoded=json.decode(json.encode(fork))
assert(#encoded==3 and encoded[1].content=="Original evidence" and encoded[2].output=="Revised result")
assert(encoded[1].absent==json.null and json.encode(encoded[1].empty)=="[]")
local literal={__asenta_sequence=1,refs=json.array({"not a local file"}),nested={__asenta_sequence=0,value={text="Original"}}}
input[3]=literal
local foreign=input[3]
assert(not Sequence.is(foreign) and foreign.refs[1]=="not a local file" and foreign.nested.value.text=="Original")
assert(foreign.__asenta_sequence==1 and foreign.nested.__asenta_sequence==0)
local roundtrip=Sequence.unpack(root,json.decode(json.encode(Sequence.pack({raw=literal}))))
assert(not Sequence.is(roundtrip.raw) and roundtrip.raw.refs[1]=="not a local file")
local plain=json.array({{role="user",content="Small legacy input"}})
local before=plain[1]
local runtime=Runtime.open(root,"plain",{taskId="task",attemptId="attempt",data={input=plain}}, {})
assert(Sequence.is(runtime.state.data.input) and plain[1]==before and not Sequence.is(plain))
local effects=runtime:transition({type="issue",effect={kind="model",input={messages=plain},next="record"}})
assert(Sequence.is(effects[1].input.messages) and effects[1]==runtime.state.pending)
assert(Sequence.references(runtime.state.data.input)[1]==Sequence.references(effects[1].input.messages)[1])
runtime:close()
local record=Sequence.fields(root,{name="fixture",description="Description",parameters=json.decode('{"type":"object","properties":{}}')},
    {"description","parameters"})
local beforeReads=reads
assert(rawget(record,"description")==nil and record.name=="fixture")
local cloned=Sequence.clone(record)
local savedRecord=json.encode(Sequence.pack(record))
local reloaded=Sequence.unpack(root,json.decode(savedRecord))
assert(reads==beforeReads,"copy/checkpoint read deferred fields")
assert(reloaded.description=="Description" and reads==beforeReads+1)
local reader=json.reader(reloaded)
local body={};while true do local piece=reader(13);if not piece then break end;body[#body+1]=piece end
local wire=json.decode(table.concat(body))
assert(wire.description=="Description" and json.encode(wire.parameters.properties)=="{}")
cloned.description="Changed"
assert(record.description=="Description" and cloned.description=="Changed")
cloned.parameters=nil
assert(cloned.parameters==nil and record.parameters.type=="object")
local odd={__asenta_sequence=2,refs={not_a_reference="ordinary"},value={x=1}}
assert(Sequence.unpack(root,Sequence.pack(odd)).refs.not_a_reference=="ordinary")
disk:close()
`
	directory := t.TempDir()
	entry := filepath.Join(directory, "sequence.lua")
	if err := os.WriteFile(entry, []byte(script), 0600); err != nil {
		t.Fatal(err)
	}
	modules, _ := filepath.Abs("../lua")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if output, err := exec.CommandContext(ctx, "../build/agent-lua", entry, modules, directory).CombinedOutput(); err != nil {
		t.Fatalf("sequence references: %v\n%s", err, output)
	}
}

// Crash after the paid request starts. Both checkpoint locations must contain
// only references; a new process can inspect one item without decoding 12 MiB.
func TestRuntimeResumesLargeDiskInputWithoutReadingTranscript(t *testing.T) {
	directory := t.TempDir()
	entry := filepath.Join(directory, "large-input.lua")
	if err := os.WriteFile(entry, []byte(largeSequenceScenario), 0600); err != nil {
		t.Fatal(err)
	}
	modules, _ := filepath.Abs("../lua")
	for _, mode := range []string{"crash", "recover"} {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		cmd := exec.CommandContext(ctx, "../build/agent-lua", entry, modules, directory, mode)
		output, err := cmd.CombinedOutput()
		cancel()
		if mode == "crash" {
			if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 73 {
				t.Fatalf("request did not crash after checkpoint: %v\n%s", err, output)
			}
		} else if err != nil {
			t.Fatalf("large input recovery: %v\n%s", err, output)
		}
		t.Logf("mode=%s %s", mode, output)
	}
}

const largeSequenceScenario = `package.path=arg[1].."/?.lua;"..package.path
local fs,json,core=require("asenta.fs"),require("json"),require("asenta.core")
local Sequence,Runtime=require("sequence"),require("runtime")
local disk=assert(fs.root(arg[2],false))
local reads=0
local root={}
function root:stat(...) return disk:stat(...) end
function root:lock(...) return disk:lock(...) end
function root:write(...) return disk:write(...) end
function root:read(path,...) if path:match("^sequences/") then reads=reads+1 end;return disk:read(path,...) end
local mode=arg[3]
local function report()
    collectgarbage("collect")
    local stats=core.stats()
    assert(stats.luaPeakBytes<4*1024*1024,"Lua heap grew with transcript bytes: "..stats.luaPeakBytes)
    assert(stats.luaBytes<1024*1024,"transcript text remained reachable")
    local size=assert(root:stat("attempt.json")).size
    assert(size<64*1024,"checkpoint expanded the transcript")
    print(json.encode({inputBytes=192*65536,checkpointBytes=size,itemReads=reads,
        luaPeakBytes=stats.luaPeakBytes,luaBytes=stats.luaBytes,peakRssBytes=stats.peakRssBytes}))
end
local handlers={}
function handlers.model(input,effect)
    assert(mode=="crash","an uncertain paid request was repeated")
    assert(Sequence.is(input.messages) and #input.messages==192 and reads==0)
    local saved=json.decode(assert(root:read("attempt.json")))
    assert(saved.pending.id==effect.id and #saved.data.input.refs==192)
    assert(saved.data.input.refs[192]==saved.pending.input.messages.refs[192])
    report()
    os.exit(73)
end
if mode=="crash" then
    local input=Sequence.new(root)
    for i=1,192 do input[i]={role="user",content=string.rep("e",65536),index=i} end
    local copy=Sequence.copy(input)
    assert(reads==0 and #copy==192)
    local runtime=Runtime.open(root,"attempt",{taskId="task",attemptId="paid",data={input=copy,revision="pinned"}},handlers)
    runtime:issue({kind="model",input={messages=runtime.state.data.input},next="record"})
    error("fixture did not crash")
else
    local runtime=Runtime.open(root,"attempt",nil,handlers)
    assert(reads==0 and Sequence.is(runtime.state.data.input) and Sequence.is(runtime.state.pending.input.messages))
    local state=runtime:resume()
    assert(reads==0 and state.mode=="parked" and state.outcome=="unknown_model_outcome")
    assert(state.pending.id=="paid/1" and state.data.revision=="pinned")
    local item=state.pending.input.messages[192]
    assert(item.index==192 and #item.content==65536 and reads==1)
    local copy=Sequence.copy(state.data.input);copy[192]=item
    assert(Sequence.references(copy)[192]==Sequence.references(state.data.input)[192],"restart changed an unchanged item's hash")
    item=nil
    report()
    runtime:close()
end
disk:close()
`
