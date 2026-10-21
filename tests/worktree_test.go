package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// The fake server persists its accepted proposal separately from the agent.
// Two real host processes prove that the retry uses the durable request, not
// an in-memory continuation after losing the server's first reply.
func TestWorktreePinnedDraftAndDurableRetry(t *testing.T) {
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(directory, "worktree.lua")
	if err := os.WriteFile(script, []byte(worktreeScenario), 0600); err != nil {
		t.Fatal(err)
	}
	luaPath, err := filepath.Abs("../lua")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	for _, phase := range []string{"queue", "resume"} {
		cmd := exec.CommandContext(ctx, "../build/agent-lua", script, directory, luaPath, phase)
		cmd.Env = append(os.Environ(), "OXTORG_WORKTREE=")
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("worktree %s: %v\n%s", phase, err, output)
		}
	}
}

const worktreeScenario = `
package.path = arg[2] .. "/?.lua;" .. package.path
local json = require("json")
local fs = require("asenta.fs")
local Worktree = require("worktree")
local test = assert(fs.root(arg[1], false))
local function clone(value) return json.decode(json.encode(value)) end
local function same(a,b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for key,value in pairs(a) do if not same(value,b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end
local identity = {organization={orgId="org"}, user={userId="agent"}}
local config = {worktreeRoot=arg[1] .. "/cache", server={baseUrl="https://fixture.invalid"}, model={alias="writer"}}
local server
if arg[3] == "queue" then
  server = {revision="r1", snapshots={}, proposals={}, posts=0, applied=0}
  server.snapshots.r1 = {workspaceId="org",worktreeId="shared",name="Shared",revision="r1",files=json.array({
    {name="notebook/index.md",text="# Index\n[Cooling](cooling.md)\n"},
    {name="notebook/cooling.md",text="# Cooling\nTemperature is normal.\n"},
    {name="notebook/reference.md",text=string.rep("Reference information. ",1000)},
    {name="role/agent.md",text="Describe observed evidence."}
  })}
else server = json.decode(assert(test:read("server.json"))) end
local function save() assert(test:write("server.json", json.encode(server))) end
local function file(snapshot, name)
  for _, entry in ipairs(snapshot.files) do if entry.name == name then return entry.text end end
end
local function revise(revision, name, text)
  local snapshot = clone(server.snapshots[server.revision])
  snapshot.revision = revision
  local found = false
  for _, entry in ipairs(snapshot.files) do
    if entry.name == name then entry.text=text; found=true end
  end
  if not found then snapshot.files[#snapshot.files+1]={name=name,text=text} end
  server.snapshots[revision], server.revision = snapshot, revision
  save()
end
local client = {config=config}
function client:request(method, path, value, model, options)
  assert(not model)
  if self.offline then error({message="connection lost"}) end
  if self.denied then error({status=403,reason="denied",message="access revoked"}) end
  if path == "/api/v1/me/worktree" then
    return {workspaceId="org",worktreeId="shared",name="Shared",revision=server.revision}, 200
  end
  local revision = path:match("^/api/v1/me/worktree/snapshot%?revision=(.*)$")
  if revision then
    local wire=json.encode(assert(server.snapshots[revision]))
    assert(options and options.consume, "snapshot must be consumed incrementally")
    for pos=1,#wire,1024 do options.consume(wire:sub(pos,pos+1023)) end
    return {},200
  end
  if path:match("^/api/v1/me/worktree/search%?") then
    assert(path:find("revision=r1",1,true))
    return {revision="r1",result={mode="hybrid",semantic="ready",indexed_chunks=1,total_chunks=1,hits=json.array({
      {path="cooling.md",heading="Cooling",from_line=2,to_line=2,excerpt="Temperature is normal."}
    })}}, 200
  end
  if path == "/api/v1/me/worktree/changes" then
    assert(method == "POST")
    server.posts = server.posts + 1
    local previous = server.proposals[value.id]
    if previous then
      assert(same(previous.request,value), "retry changed the exact request")
      save()
      return clone(previous.publication), 200
    end
    local base, current = assert(server.snapshots[value.baseRevision]), server.snapshots[server.revision]
    local conflicts = json.array()
    for _, change in ipairs(value.changes) do
      if file(base,change.name) ~= file(current,change.name) then conflicts[#conflicts+1]=change.name end
    end
    local publication = {id=value.id,state="conflict",conflicts=conflicts}
    if #conflicts == 0 then
      assert(#value.changes == 1 and not value.changes[1].delete)
      revise("r3", value.changes[1].name, value.changes[1].text)
      publication = {id=value.id,state="published",revision="r3"}
      server.applied = server.applied + 1
    end
    server.proposals[value.id] = {request=clone(value),publication=publication}
    save()
    if self.loseReply then self.loseReply=false; error({message="reply lost after acceptance"}) end
    return clone(publication), 200
  end
  local id = path:match("^/api/v1/me/worktree/changes/(.+)$")
  if id then return clone(assert(server.proposals[id]).publication), 200 end
  error("unexpected request: " .. method .. " " .. path)
end
local manager = Worktree.new(config, client, identity)
if arg[3] == "queue" then
  local original = assert(manager:enter("task", "owner"))
  local stored = assert(manager:_root():read(original.attempt,1048576))
  assert(#stored < 8192 and not stored:find("Reference information",1,true),
    "the draft must contain metadata, never source bodies")
  local found = original:search("temperature", 5)
  assert(found.hits[1].path == "cooling.md")
  assert(original:read("notebook/" .. found.hits[1].path):find(found.hits[1].excerpt,1,true))
  revise("r2", "checks/revision.txt", "Independent server update.")
  local newer = assert(manager:enter("other-task", "owner"))
  assert(newer.revision == "r2" and original.revision == "r1")
  -- Existing installations keep their uncompressed checkpoint until the next
  -- write. Both encodings must restore the same pinned content and authority.
  local inline=clone(newer.state)
  inline.storage=nil
  for _,key in ipairs({"snapshot","commitBase"}) do
    inline[key].storage=nil
    for _,file in ipairs(inline[key].files) do file.text=manager:_read(file.blob);file.blob=nil end
  end
  for _,key in ipairs({"files","observed","checkpoint"}) do
    for name,ref in pairs(inline[key]) do inline[key][name]=manager:_read(ref) end
  end
  assert(manager:_root():write(newer.attempt,json.encode(inline)))
  local legacy = assert(manager:enter("other-task","owner","r2"))
  assert(legacy.revision == newer.revision and legacy:read("notebook/reference.md") == newer:read("notebook/reference.md"))
  assert(not pcall(original.read, original, "checks/revision.txt"))
  original:write("role/agent.md", "Private instruction draft.")
  assert(original.role == "Describe observed evidence.")
  original:write("notebook/cooling.md", "# Cooling\nRadiator remains cool.\n")
  local localHits = original:search("radiator", 5)
  assert(localHits.hits[1].path == "cooling.md" and localHits.detail:find("literal",1,true))
  client.loseReply = true
  local publication = original:submit({"notebook/cooling.md"}, "Record cooling observation", "Fixture measurement")
  assert(publication.state == "queued" and server.applied == 1)
  assert(original.revision == "r1" and original.role == "Describe observed evidence.")
  assert(test:write("queued-id",publication.id))
else
  assert(manager:sync())
  assert(server.applied == 1 and server.posts == 2, "retry duplicated publication")
  local queued = assert(test:read("queued-id"))
  assert(server.proposals[queued].publication.revision == "r3")
  local resumed = assert(manager:enter("task", "owner", "r1"))
  assert(resumed.revision == "r1" and resumed.state.snapshot.revision == "r1")
  assert(resumed.state.commitBase.revision == "r3", "publication acknowledgement lost its separate draft base")
  assert(resumed:read("notebook/cooling.md") == "# Cooling\nRadiator remains cool.\n")
  assert(resumed:read("role/agent.md") == "Private instruction draft.")
  assert(resumed.role == "Describe observed evidence.", "restart changed the attempt's published role")
  assert(not pcall(resumed.read,resumed,"checks/revision.txt"), "restart rebased the attempt")
  local current = assert(manager:enter("task", "owner"))
  assert(current.revision == "r3")
  assert(current:read("notebook/cooling.md") == "# Cooling\nRadiator remains cool.\n")
  assert(current:read("role/agent.md") == "Private instruction draft.")
  assert(current.role == "Describe observed evidence.", "draft role became an instruction")
  client.offline = true
  manager:close()
  manager = Worktree.new(config,client,identity)
  local offline = assert(manager:enter("task", "owner"))
  assert(offline.revision == "r3" and offline:read("notebook/cooling.md") == current:read("notebook/cooling.md"))
  client.offline = false
  client.denied = true
  assert(not pcall(manager.enter,manager,"denied-task","owner"), "403 reused cached assignment")
  client.denied = false
  offline = assert(manager:enter("task", "owner"))
  offline:set_provenance({alias="writer",model="actual-writer"},"external")
  offline:write("notebook/cooling.md", "# Cooling\nPrivate conflicting observation.\n")
  revise("r4", "notebook/cooling.md", "# Cooling\nOther confirmed observation.\n")
  local conflict = offline:submit({"notebook/cooling.md"}, "Record private observation", "Fixture measurement")
  assert(conflict.state == "conflict")
  assert(offline:read("notebook/cooling.md"):find("Private conflicting",1,true))
  local fresh = assert(manager:enter("task", "owner"))
  assert(fresh.revision == "r4" and fresh:read("notebook/cooling.md"):find("Other confirmed",1,true))
  assert(offline.revision == "r3" and offline:read("notebook/cooling.md"):find("Private conflicting",1,true))
  local archived
  for _, draft in ipairs(fresh:drafts()) do
    if draft.conflicts and draft.conflicts[1] == "notebook/cooling.md" then archived=draft end
  end
  assert(archived, "conflicting draft was lost")
  assert(fresh:read("notebook/cooling.md",archived.id):find("Private conflicting",1,true))
  assert(fresh:restore(archived.id,"notebook/cooling.md"))
  assert(fresh:read("notebook/cooling.md"):find("Private conflicting",1,true))
  assert(server.revision == "r4" and server.applied == 1, "restoring a draft published it")
end
manager:close()
test:close()
`
