package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestInstalledMutatorPipeline(t *testing.T) {
	directory := t.TempDir()
	script := filepath.Join(directory, "mutators.lua")
	if err := os.WriteFile(script, []byte(`package.path=arg[1] .. "/?.lua;" .. package.path
local Mutators, Registry, json = require("mutators"), require("registry"), require("json")
local count, later, mode = 0, 0, "normal"
local accepted
package.preload["fixture.installation"] = function()
    return {
        {name="z-note",digest="installed-z",hooks={
            BeforeTurn=function(turn) turn.note="  One turn only  "; return turn end,
            BeforeTool=function(call) later=later+1; assert(call.args.query == "clean"); return {allow=true} end,
            AfterTool=function(call,out) assert(call.name == "read"); out.text=out.text .. " [checked]"; return out end}},
        {name="a-redact",digest="installed-a",description="Installed stateful hook",hooks={
            BeforeTurn=function(turn,ctx)
                assert(type(ctx.cancelled) == "function" and ctx.deadlineMs > 0 and ctx.taskId == "task-one")
                if mode == "bad-role" then turn.messages[1].role="user"; return turn end
                if mode == "bad-count" then table.remove(turn.messages); return turn end
                for _, message in ipairs(turn.messages) do message.text=message.text:gsub("secret", "redacted") end
                return turn
            end,
            BeforeTool=function(call)
                count=count+1
                if mode == "refuse" then return {reason="Stop here"} end
                if mode == "broken" then error("accepted hook broke") end
                if mode == "bad-args" then return {allow=true,replace=true,args={count=4}} end
                assert(call.args.count == "4" and call.args.nested == '{"one":true}' and call.args.absent == nil)
                call.args.query="clean"; call.args.remove=nil
                return {allow=true,replace=true,args=call.args}
            end,
            AfterTool=function(_,out) out.text=out.text:gsub("secret", "redacted"); out.isError=false; return out end,
            Call=function(input) return {text=input.args.value .. ":" .. count, isError=false} end}}
    }
end
accepted=require("fixture.installation")
local context={taskId="task-one"}
local shelf=Mutators.new(accepted,{context=function() return context end})
local report=shelf:report()
assert(#report == 2 and report[1].name == "a-redact" and report[1].digest == "installed-a")
assert(#report[1].entries == 4 and report[1].entries[1] == "Call")
report[1].entries[1]="bad"
assert(shelf:report()[1].entries[1] == "Call")
-- Replacing the installation table does not replace this attempt's hooks.
accepted[2].hooks.Call=function() error("new installation") end
local input=json.array({{role="system",content="keep secret",call_id="fixed",opaque={one=true}},
    {role="user",content="question"}})
local messages,changed=shelf:before_turn(1,input)
assert(#messages == 3 and messages[1].content == "keep redacted" and messages[3].role == "system")
assert(messages[3].content == "One turn only" and messages[1].call_id == "fixed" and messages[1].opaque.one)
assert(#changed == 2 and changed[1] == "a-redact" and changed[2] == "z-note")
assert(#input == 2 and input[1].content == "keep secret")
messages=shelf:before_turn(2,input)
assert(#messages == 3)
local call={name="read",id="call-one",args={query="secret",count=4,nested={one=true},remove="old",absent=json.null}}
local replaced,ruling=shelf:before_tool(call)
assert(not ruling.refusal and #ruling.changedBy == 1 and ruling.changedBy[1] == "a-redact" and later == 1)
assert(replaced.id == "call-one" and replaced.args.query == "clean" and replaced.args.count == 4)
assert(replaced.args.nested.one and replaced.args.remove == nil and replaced.args.absent == nil)
assert(call.args.query == "secret" and call.args.remove == "old" and call.args.absent == json.null)
local result={text='{"secret":"value"}',isError=true}
local rewritten,names=shelf:after_tool(replaced,result)
assert(rewritten.text == '{"redacted":"value"} [checked]' and not rewritten.isError and #names == 2)
assert(result.text == '{"secret":"value"}' and result.isError)
local registry=Registry.new()
local tools=shelf:tools()
assert(#tools == 1 and tools[1].name == "own.a-redact" and tools[1].program == "installed-a")
registry:add(tools[1])
local answer=registry:invoke{name="own_a-redact",args={value=9}}
assert(not answer.error and answer.output == "9:1",answer.output)
mode="refuse"
local unchanged,refused=shelf:before_tool(call)
assert(refused.refusal:find("Stop here",1,true) and refused.refusal:find("a-redact",1,true) and later == 1)
assert(unchanged.args.query == "secret" and #refused.changedBy == 0)
local function broken(entry,fn)
    local ok,err=pcall(fn)
    assert(not ok and type(err) == "table" and err.reason == "mutator_broken",tostring(err))
    assert(err.mutator == "a-redact" and err.entry == entry and err.message:find(entry,1,true))
end
mode="broken"
broken("BeforeTool",function() shelf:before_tool(call) end)
assert(later == 1)
mode="bad-args"
broken("BeforeTool",function() shelf:before_tool(call) end)
mode="bad-role"
broken("BeforeTurn",function() shelf:before_turn(3,input) end)
mode="bad-count"
broken("BeforeTurn",function() shelf:before_turn(3,input) end)
mode="normal"
context={taskId="task-one",deadlineMs=0}
local old=count
broken("BeforeTool",function() shelf:before_tool(call) end)
assert(count == old)
context={taskId="task-one",cancelled=function() return true end}
broken("BeforeTool",function() shelf:before_tool(call) end)
assert(count == old)
-- Provider-specific items require an explicit reversible text mapping.
context={taskId="task-one"}
local provider={{type="function_call_output",call_id="paired",output="secret"}}
assert(not pcall(shelf.before_turn,shelf,1,provider))
local adapted=Mutators.new({{name="redact",digest="adapter",hooks={BeforeTurn=function(turn)
    turn.messages[1].text="redacted"; return turn
end}}},{messageText=function(item) return "tool",item.output end,
    withText=function(item,text) item.output=text; return item end})
local sent,marked=adapted:before_turn(1,provider)
assert(sent[1].output == "redacted" and sent[1].call_id == "paired" and sent[1].content == nil)
assert(provider[1].output == "secret" and marked[1] == "redact")
adapted:close(); shelf:close()
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
		t.Fatalf("installed mutator contract failed: %v\n%s", err, output)
	}
}
