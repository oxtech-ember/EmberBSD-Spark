package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestProvenanceKeepsSourcesAcrossTurnsAndRestart(t *testing.T) {
	script := filepath.Join(t.TempDir(), "provenance.lua")
	if err := os.WriteFile(script, []byte(provenanceScenario), 0600); err != nil {
		t.Fatal(err)
	}
	modules, err := filepath.Abs("../lua")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if output, err := exec.CommandContext(ctx, "../build/agent-lua", script, modules).CombinedOutput(); err != nil {
		t.Fatalf("provenance sources and restart: %v\n%s", err, output)
	}
}

const provenanceScenario = `
package.path = arg[1] .. "/?.lua;" .. package.path
local json, Provenance, Registry = require("json"), require("provenance"), require("registry")
local registry = Registry.new()
local function tool(name,traits)
  traits.name,traits.class,traits.invoke=name,traits.provenance and "write_local" or "read",function() return "" end
  return registry:add(traits)
end
local web = tool("web_read",{})
local ownMCP = tool("sensor_read",{foreign=false})
local notes = tool("notebook_read",{kept=true,bringsNothingIn=true})
local memory = tool("remember",{provenance="quarantine",bringsNothingIn=true})
local writer = tool("worktree_write",{provenance="whole",bringsNothingIn=true})
local recall = tool("recall",{echoes=true})
local composed = tool("model_program",{composes=true})
local author = {modelAlias="actual-seat",model="Actual Model"}
local options = {registry=registry,actorId="agent",task={title="Read HTTPS://person.example/manual"},
  role="Inspect https://role.example/guide .",notebook="A kept head https://kept.example/note\"?private=1",history={
    {actorId="owner",kind="message",body="Read https://human.example/card"},
    {actorId="colleague",actorIsAgent=true,kind="message",body="I guessed https://invented.example/colleague"},
    {actorId="agent",kind="message",level="trace",title="web_read",stepId="old",quoted="{}",
      body="The address https://invented.example/refused was not given",errorCode="mutator_refused"}
  }}
local chain = Provenance.new(options)
local function call(descriptor,args,raw)
  return {name=descriptor.modelName,args=args,arguments=raw or json.encode(args)}
end
local function allowed(current,descriptor,args,step)
  return current:before(call(descriptor,args),descriptor,{stepId=step or "one",reply=author})
end
assert(allowed(chain,web,{url="https://person.example/manual"}))
assert(allowed(chain,web,{url="https://human.example/card"}))
assert(allowed(chain,web,{url="https://role.example/guide"}))
assert(allowed(chain,web,{url="https://kept.example/note"}))
assert(not allowed(chain,web,{url='https://kept.example/note"?private=1'}))
assert(not allowed(chain,web,{url="https://invented.example/colleague"}))
assert(not allowed(chain,web,{url="https://invented.example/refused"}))
local encoded = [[{"content":"https:\/\/invented.example\/inside"}]]
assert(not chain:before(call(writer,json.decode(encoded),encoded),writer,{stepId="one",reply=author}))

local voluntary = call(memory,{origin="external",text="A cautious fact"})
assert(chain:before(voluntary,memory,{stepId="one",reply=author}) and voluntary.args.origin == "external")
assert(not voluntary.quarantined and not chain.state.external)
local raw = [[{"limit":1234567890123456789,"ratio":1.0000,"origin":"external","author":{"alias":"fake"}}]]
local marked = call(writer,json.decode(raw),raw)
assert(chain:before(marked,writer,{stepId="one",reply=author}))
assert(marked.args.origin == "agent" and marked.args.author.alias == "actual-seat" and marked.args.author.model == "Actual Model")
assert(marked.arguments:find('"limit":1234567890123456789',1,true) and marked.arguments:find('"ratio":1.0000',1,true))

local actual = "https://data.example/card?a=1&b=2"
local request = call(ownMCP,{query="temperature"})
assert(chain:before(request,ownMCP,{stepId="one",reply=author}))
chain:heard(request,{tool=ownMCP,output=[[{"url":"https:\/\/data.example\/card?a=1\u0026b=2"}]],raw={}})
assert(chain.state.external and chain:context(author).origin == "external","own MCP result lost outside-input provenance")
assert(not allowed(chain,web,{url=actual},"one"),"a sibling call borrowed a later answer")
assert(allowed(chain,web,{url=actual},"two"),"decoded server JSON did not give its address")
local quarantined = call(memory,{origin="agent",text="A fact from the supplied data"})
assert(chain:before(quarantined,memory,{stepId="two",reply=author}))
assert(quarantined.args.origin == "external" and quarantined.args.author == nil and quarantined.quarantined)

-- A kept source preserves checked addresses, not an arbitrary string formed
-- from a checked head and a quote/query that appeared in model-authored prose.
local note = "See " .. actual .. '"?private=7'
assert(allowed(chain,writer,{content=note},"two"))
chain:heard(call(notes,{}),{tool=notes,output=json.encode({source="notebook/knowledge/cooling.md",text=note}),raw={}})
assert(allowed(chain,web,{url=actual},"three"))
assert(not allowed(chain,web,{url=actual .. '"?private=7'},"three"))
local nested = json.encode({payload=json.encode({payload="https://invented.example/nested"})})
assert(not allowed(chain,writer,{content=nested},"three"),"JSON nested inside a string bypassed the write check")

chain:heard(call(recall,{}),{tool=recall,output="https://invented.example/echo",raw={given="https://source.example/recalled"}})
chain:heard(call(composed,{}),{tool=composed,output="https://invented.example/program",raw={steps={
  {title="web_read",quoted="{}",body="https://source.example/nested-step"},
  {title="web_read",quoted="{}",body="https://invented.example/failed-step",isError=true}
}}})
chain:heard(call(web,{}),{tool=web,output='{"url":"https:\\/\\/source.example\\/before-cut","unfinished":',raw={}})
assert(allowed(chain,web,{url="https://source.example/recalled"},"four"))
assert(allowed(chain,web,{url="https://source.example/nested-step"},"four"))
assert(allowed(chain,web,{url="https://source.example/before-cut"},"four"),"truncated JSON lost a complete prior string")
assert(not allowed(chain,web,{url="https://invented.example/echo"},"four"))
assert(not allowed(chain,web,{url="https://invented.example/program"},"four"))
assert(not allowed(chain,web,{url="https://invented.example/failed-step"},"four"))
chain:heard(call(ownMCP,{}),{tool=ownMCP,output=string.rep("Telemetry without addresses. ",20000),raw={}})
assert(#chain.state.given<4096,"provenance retained entire tool text instead of address metadata")
local resumed = Provenance.new(options,json.decode(json.encode(chain.state)))
assert(resumed.state.external and allowed(resumed,web,{url=actual},"five"))
assert(not allowed(resumed,web,{url="https://invented.example/refused"},"five"))
local newTask = Provenance.new{registry=registry,actorId="agent",task={},notebook=note}
assert(allowed(newTask,web,{url=actual}) and not allowed(newTask,web,{url=actual .. '"?private=7'}))
`
