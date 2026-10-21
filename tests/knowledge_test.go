package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestKnowledgePathsAndPinnedSources(t *testing.T) {
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(directory, "knowledge.lua")
	if err := os.WriteFile(script, []byte(knowledgeScenario), 0600); err != nil {
		t.Fatal(err)
	}
	modules, err := filepath.Abs("../lua")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "../build/agent-lua", script, directory, modules)
	cmd.Env = append(os.Environ(), "OXTORG_WORKTREE=")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("knowledge paths and pinned sources: %v\n%s", err, output)
	}
}

const knowledgeScenario = `
package.path = arg[2] .. "/?.lua;" .. package.path
local json, Worktree, Knowledge, Registry = require("json"), require("worktree"), require("knowledge"), require("registry")
local function clone(value) return json.decode(json.encode(value)) end
local shared = {name="cooling",summary="Observe cooling",text="Check the measured temperature.",version=2,
  files=json.array({{name="shared.txt",content="Shared sample bytes."}}),
  tools=json.array({{name="shared_tool",environment="lua",files=json.array({{name="main.lua",content="return 7"}})}})}
local snapshot = {workspaceId="org",worktreeId="tree",revision="r2",files=json.array({
  {name="notebook/index.md",text="# Index\n[Cooling](knowledge/cooling.md)\n"},
  {name="notebook/knowledge/cooling.md",text="# Cooling\nTemperature is normal.\n"},
  {name="role/agent.md",text="Describe observed evidence."},
  {name="skills/cooling/skill.json",text=json.encode(shared)},
  {name="skills/unpermitted/skill.json",text=json.encode({name="unpermitted",text="Unpermitted instruction."})}
})}
local config = {worktreeRoot=arg[1] .. "/cache",server={baseUrl="https://fixture.invalid"},model={alias="writer"}}
local client = {config=config,revision="r2"}
function client:request(method,path,value,model,options)
  assert(method == "GET" and value == nil and not model)
  if path == "/api/v1/me/worktree" then
    return {workspaceId="org",worktreeId="tree",revision=self.revision},200
  end
  local revision = path:match("^/api/v1/me/worktree/snapshot%?revision=(.*)$")
  if revision then
    local result = clone(snapshot)
    result.revision = revision
    if revision == "r1" then result.files[2].text="# Cooling\nOriginal published observation.\n" end
    options.consume(json.encode(result))
    return {},200
  end
  if path:match("^/api/v1/me/worktree/search%?") then
    assert(path:find("revision=r2",1,true),"search lost its attempt revision")
    return {revision="r2",result={mode="hybrid",semantic="ready",hits=json.array({
      {path="knowledge/cooling.md",heading="Cooling",from_line=2,to_line=2,excerpt="Temperature is normal."}
    })}},200
  end
  if path:match("^/api/v1/me/worktree/history%?") then
    return {entries=json.array({
      {state="published",revision="r3",publishedBaseRevision="r2",message="Newer publication",publishedAt="2026-10-05T12:00:00Z"},
      {state="published",revision="r1",publishedBaseRevision="",message="First publication",publishedAt="2026-10-05T10:00:00Z"},
      {state="pending",revision="",message="Unpublished proposal"},
      {state="published",revision="r2",publishedBaseRevision="r1",message="Pinned publication",publishedAt="2026-10-05T11:00:00Z"}
    })},200
  end
  if path == "/api/v1/skills?revision=r2" then
    return {skills=json.array({{name="cooling",summary="Installed summary",text="Use observed evidence.",version=1,tools=json.null,
      files=json.array({{name="installed.txt",content="Installed sample bytes."}})}})},200
  end
  error("unexpected request: " .. path)
end
local manager = Worktree.new(config,client,{organization={orgId="org"},user={userId="agent"}})
local view = assert(manager:enter("task","owner"))
view:set_provenance({alias="trusted",model="actual-writer"},"external")
local registry = Registry.new()
for _, tool in ipairs(Knowledge.tools(view,{client=client})) do registry:add(tool) end
assert(#Knowledge.tools(nil) == 0 and #registry:definitions() == 11)
assert(registry:find("notebook_read").source == "" and registry:find("notebook_read").group == "oxtorg-native")
local function invoke(name,args)
  local result = registry:invoke{name=name,args=args}
  assert(not result.error,result.output)
  return json.decode(result.output)
end
local search = invoke("notebook_search",{query="temperature"})
local hit = search.hits[1]
assert(search.revision == "r2" and hit.path == "knowledge/cooling.md" and hit.source == "notebook/knowledge/cooling.md")
local note = invoke("notebook_read",{path=hit.path,from_line=hit.from_line})
assert(note.path == hit.path and note.source == hit.source and note.revision == "r2")
assert(note.text:find(hit.excerpt,1,true) and note.from_line == 2 and note.total_lines == 2)
local listed = invoke("notebook_read",{})
assert(listed.paths[1] == "index.md" and listed.paths[2] == hit.path)
assert(registry:invoke{name="notebook_read",args={path="../role/agent.md"}}.error,"relative path escaped notebook")
assert(registry:invoke{name="notebook_write",args={path="/outside.md",content="Outside"}}.error,"absolute path was accepted")
assert(registry:find("notebook_write").class == "write_local")
assert(registry:find("notebook_write").parameters.properties.author == nil)
invoke("notebook_write",{path=hit.path,content="# Cooling\nPrivate radiator observation.\n",author={alias="untrusted"},origin="agent"})
local mark = view.state.provenance[hit.source]
assert(mark.origin == "external" and #mark.authors == 1 and mark.authors[1].alias == "trusted","model arguments replaced trusted provenance")
invoke("worktree_write",{path="role/agent.md",content="Private role draft."})
invoke("worktree_write",{path="skills/cooling/skill.json",content=json.encode({name="cooling",text="Private skill draft."})})
assert(registry:invoke{name="worktree_write",args={path=hit.source,content="Bypass notebook"}}.error)
assert(view.role == "Describe observed evidence.")
local skills = Knowledge.skills(view,{client=client,task={skills={"cooling"}}})
assert(#skills.catalogue == 1 and skills.revision == "r2" and #skills.selected == 1)
assert(skills.text:find("Use observed evidence.",1,true) and skills.text:find("Check the measured temperature.",1,true))
assert(not skills.text:find("Private skill",1,true) and #skills.selected[1].files == 2 and skills.selected[1].tools[1].files[1].content == "return 7")
assert(next(json.null) == nil,"merging a null installed tool list mutated the JSON null sentinel")
client.revision = "r3"
local history = invoke("worktree_git",{action="log",limit=10})
assert(#history.commits == 2 and history.commits[1].hash == "r2" and history.commits[2].hash == "r1","history followed display order or a newer head")
local published = invoke("notebook_git",{action="show",path=hit.path,revision="HEAD"})
assert(published.path == hit.path and published.source == hit.source and published.revision == "r2" and published.view == "published")
assert(published.text == "# Cooling\nTemperature is normal.\n","HEAD read a draft")
local old = invoke("worktree_git",{action="show",path=hit.source,revision="r1"})
assert(old.path == hit.source and old.revision == "r1" and old.text:find("Original published",1,true))
assert(view.revision == "r2" and view:read(hit.source):find("Private radiator",1,true))
local check = invoke("worktree_selfcheck",{paths={hit.source}})
assert(check.passed and check.scope == "source-bounds-and-layout")
manager:close()
`
