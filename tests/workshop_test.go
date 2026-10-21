package probe

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestLuaWorkshopBuildReviewAndProcess(t *testing.T) {
	interpreter, err := exec.LookPath("lua5.5")
	if err != nil {
		t.Fatal("the workshop requires the common Lua 5.5 interpreter: ", err)
	}
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	entry := `local helper = require("helper")
return function(args)
    if args.value == "spin" then while true do end end
    local path = assert(os.getenv("OXTORG_TOOL_DATA")) .. "/counter"
    local old = io.open(path, "r")
    local count = old and tonumber(old:read("*a")) or 0
    if old then old:close() end
    local file = assert(io.open(path, "w")); file:write(count + 1); file:close()
    return {echo=helper.echo(args.value), count=count + 1, declared=os.getenv("WORKSHOP_FIXTURE"), empty={},
        isolated=os.getenv("ASENTA_WORKSHOP_SECRET") == nil, standard=type(os.execute) == "function"}
end`
	helper := `return {echo=function(value) return value end}`
	// This is the Go workshop's actual review projection and SourcesDigest
	// framing, checked against the bytes submitted by the Lua adapter.
	type param struct {
		Name        string `json:"name"`
		Description string `json:"description"`
		Required    bool   `json:"required"`
	}
	card, err := json.MarshalIndent(struct {
		Name        string   `json:"name"`
		Summary     string   `json:"summary"`
		Environment string   `json:"environment"`
		Params      []param  `json:"params"`
		Network     bool     `json:"network"`
		Env         []string `json:"env,omitempty"`
		Reads       []string `json:"reads,omitempty"`
	}{"echo", "Echo <value> & keep state", "lua", []param{{"value", "Literal value", true}}, false, []string{"WORKSHOP_FIXTURE"}, nil}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.New()
	for _, file := range []struct{ name, text string }{{"tool.json", string(card)}, {"main.lua", entry}, {"helper.lua", helper}} {
		fmt.Fprintf(digest, "%d:%s\x00%d:%s", len(file.name), file.name, len(file.text), file.text)
	}
	write := func(name, text string) string {
		t.Helper()
		path := filepath.Join(directory, name)
		if err := os.WriteFile(path, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	write("main.lua", entry)
	write("helper.lua", helper)
	write("projection.json", string(card))
	script := write("workshop.lua", `package.path = arg[1] .. "/?.lua;" .. package.path
local Workshop, json, fs = require("workshop"), require("json"), require("asenta.fs")
local directory, expected = arg[2], arg[3]
local root=assert(fs.root(directory,false))
local states, submissions = {}, 0
local client={}
function client:request(method,path,body)
    if method == "GET" then assert(path == "/api/v1/me/tools/reviews"); return {tools=states} end
    assert(method == "PUT" and path == "/api/v1/me/tools/echo/review")
    assert(body.files[1].name == "tool.json" and body.files[1].text == root:read("projection.json",65536), body.files[1].text)
    assert(body.built and body.taskId == "task-one" and body.origin == "external" and body.author.model == "known-model")
    submissions=submissions+1
    states={{name="echo",digest=expected,state="pending",built=true,taskId="task-one"}}
    return {candidate={digest=expected,state="pending"}}
end
local config={workshop={lua=arg[4]},limits={workshop=true,sandbox="warn",workRoot=directory .. "/work",toolOutput=4096},server={tokenEnv="ASENTA_WORKSHOP_SECRET"}}
local context={origin="external",author={model="known-model"}}
local workshop=Workshop.new(config,client,{root=directory .. "/shelf",stateRoot=directory .. "/state",timeoutMs=500})
local task={taskId="task-one",ownerId="owner"}
local tools=workshop:tools(task,nil,context)
assert(#tools == 1 and tools[1].name == "build_tool" and tools[1].provenance == "whole" and tools[1].growsShelf)
local built=tools[1].invoke{name="echo",summary="Echo <value> & keep state",environment="lua",network=false,
    params={{name="value",description="Literal value",required=true}},env={"WORKSHOP_FIXTURE"},
    files={{name="main.lua",text=root:read("main.lua",65536)},{name="helper.lua",text=root:read("helper.lua",65536)}}}
assert(not built.isError, built.content[1].text)
assert(built.structuredContent.program == expected and submissions == 1)
tools=workshop:tools(task,nil,context)
assert(#tools == 2 and tools[2].name == "own.echo" and tools[2].class == "exec" and tools[2].source == "")
assert(tools[2].built and tools[2].composes and tools[2].program == expected)
local literal="quote' ; $(uname)\nnext"
local reply=tools[2].invoke{value=literal}
assert(not reply.isError,reply.content[1].text)
local value=json.decode(reply.structuredContent.output)
assert(value.echo == literal and value.count == 1 and value.declared == "passed" and value.isolated and value.standard)
assert(getmetatable(value.empty).__jsontype == "object")
local missing=tools[2].invoke{value=json.null}
assert(missing.isError and missing.content[1].text:find("missing parameter",1,true))
local later=workshop:tools({taskId="task-two",ownerId="owner"},nil,context)
assert(#later == 1 and workshop.held.echo)
states[1].state="admitted"
later=workshop:tools({taskId="task-two",ownerId="owner"},nil,context)
reply=later[2].invoke{value="again"}
assert(not reply.isError,reply.content[1].text)
assert(json.decode(reply.structuredContent.output).count == 2)
reply=later[2].invoke{value="spin"}
assert(reply.isError and reply.structuredContent.outcomeUnknown)
context.cancelled=function() return true end
reply=later[2].invoke{value="canceled"}
assert(reply.isError and reply.structuredContent.outcomeUnknown)
context.cancelled=nil

-- A selected skill executes its pinned files without a persistent shelf data path.
context.skills={{name="fixture",tools={{name="fixture.read",summary="Read fixture",environment="lua",params={},
    files={{name="read.lua",content='return function() return {noData=os.getenv("OXTORG_TOOL_DATA")==nil} end'}}}}}}
later=workshop:tools(task,nil,context)
assert(later[3].name == "skill.fixture.read" and later[3].class == "exec")
reply=later[3].invoke{}
assert(not reply.isError and json.decode(reply.structuredContent.output).noData)
context.skills=nil
local shelf=assert(fs.root(directory .. "/shelf/owner",false))
assert(shelf:write("tools/echo/main.lua","return function() return 'changed' end"))
reply=tools[2].invoke{value="old"}
assert(reply.isError and reply.content[1].text:find("changed after",1,true))
local card=json.decode(assert(shelf:read("tools/echo/tool.json",65536)))
assert(card.uses == 5 and card.author == "assistant" and card.origin == "external")
shelf:close()
workshop:close(); root:close()
assert(#Workshop.new({limits={workshop=false}},client):tools(task) == 0)
assert(not pcall(Workshop.new,{limits={workshop=true,sandbox="required"}},client,{root=directory .. "/shelf"}))
`)
	binary, _ := filepath.Abs("../build/agent-lua")
	modules, _ := filepath.Abs("../lua")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, script, modules, directory, hex.EncodeToString(digest.Sum(nil)), interpreter)
	cmd.Env = append(os.Environ(), "WORKSHOP_FIXTURE=passed", "ASENTA_WORKSHOP_SECRET=private", "OXTORG_SANDBOX=", "OXTORG_WORKSHOP_OFF=0")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("Lua workshop contract failed: %v\n%s", err, output)
	}
}
