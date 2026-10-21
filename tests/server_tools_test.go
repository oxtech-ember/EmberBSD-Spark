package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestServerToolsPreservePayloadsAndProvenance(t *testing.T) {
	script := `package.path = arg[1] .. "/?.lua;" .. package.path
local json, Tools, Registry = require("json"), require("server_tools"), require("registry")
local calls, mode = {}, "normal"
local bound = {"https://allowed.example"}
local client = {config={model={memory=true}}, readBound=bound}
local human = {eventId="human-1", body="https://human.example", actorIsAgent=false}
local model = {eventId="model-1", body="https://invented.example", actorIsAgent=true}
local outside = {eventId="outside-1", body="https://source.example", actorIsAgent=true, outside=true}
function client:request(method, path, body)
    calls[#calls + 1] = {method=method, path=path, body=body}
    if mode == "refused" then error({status=409, reason="conflict", message="A newer version stands", body={current=9}}, 0) end
    if path:find("/me/failures", 1, true) then return {layer="published", layerVersion=4} end
    if path == "/api/v1/me/role/layer" then return {role={agentLayer="standing"}, candidate={state="pending"}} end
    if path == "/api/v1/me/ceiling" then return {role={version=5, ceilings={body}}} end
    if path:find("/market/helpers", 1, true) then return {helpers={{userId="helper", taskId="past"}}} end
    if path:find("/market/fund", 1, true) then error({status=409, reason="market_off", message="No market"}, 0) end
    if path:find("/org/outcomes", 1, true) then return {units=17, outcomes={succeeded=2}} end
    if path == "/api/v1/skills/missing/versions" then error({status=404, message="missing"}, 0) end
    if path == "/api/v1/skills" then return {skills={{name="repair"}}} end
    if path == "/api/v1/skills/repair/versions" then
        local versions = {}
        for i=1,13 do versions[i]={version=14-i} end
        return {layer={name="repair", installedText="customer", text="agent"}, versions=versions}
    end
    if path == "/api/v1/skills/repair/layer" then return {layer={name="repair", text="old"}, candidate={state="running"}} end
    if path:find("/search?", 1, true) then return {hits={{event=human, ends={model}, before={outside}, after={}}}} end
    if path:find("/events/", 1, true) then return {event=model, task={taskId="past", title="Past matter"}} end
    if path:find("/facts", 1, true) then return {state="pending", warning="secret"} end
    error("unexpected endpoint: " .. path)
end
function client:history()
    return {human, {eventId="investigation-1", investigation={question="Why?"}},
        {eventId="recalled", body="old", recalledAt="yesterday"}, {eventId="trace", body="call", level="trace", phase="start"}}
end
function client:append(event)
    self.written=event
    return {eventId="investigation-2", investigation=event.investigation}
end
local context = {origin="external", author={alias="worker", model="known-model"}}
local options = {context=function() return context end, materialTask="parent/task", compacts=false}
local descriptors = Tools.tools(client, {taskId="current", ownerId="person/one"}, options)
assert(#descriptors == 11)
local registry = Registry.new()
for _, descriptor in ipairs(descriptors) do registry:add(descriptor) end
local function call(name, args)
    local reply=registry:invoke{name=name, args=args or {}}
    assert(not reply.error, reply.output)
    return reply.raw.structuredContent, reply.raw
end
local function sent(method, path)
    local request=calls[#calls]
    assert(request.method == method and request.path == path, request.path)
    return request.body
end
assert(registry:find("remember").class == "write_local" and registry:find("remember").provenance == "quarantine")
assert(registry:find("my_failures").echoes and registry:find("read_original").readsRecords)
assert(registry:find("my_failures").group == "oxtorg-native" and registry:find("read_original").source == "")
assert(registry:find("read_skill").kept and not registry:find("read_skill").foreign)
assert(registry:find("search_history").foreign and registry:find("teach_myself").provenance == "whole")
call("my_failures")
sent("GET", "/api/v1/me/failures?days=7")
local response=call("teach_myself", {layer="lesson", basis="failures", origin="agent", author={model="forged"}, taskId="wrong"})
local body=sent("PUT", "/api/v1/me/role/layer")
assert(body.layer == "lesson" and body.origin == "external" and body.author.model == "known-model" and body.taskId == "current")
assert(response.role.agentLayer == "standing" and response.candidate.state == "pending")
call("set_my_ceiling", {variable="turns", value=12, basis="ran out"})
body=sent("PUT", "/api/v1/me/ceiling")
assert(body.value == 12 and body.origin == "external" and body.author == nil)
local before=#calls
assert(registry:invoke{name="set_my_ceiling", args={variable="compaction", value=100, basis="needed"}}.error and #calls == before)
assert(call("who_helped_me").marketOff)
sent("GET", "/api/v1/market/fund?subjectId=person%2Fone")
assert(call("org_outcomes", {days=14}).units == 17)
sent("GET", "/api/v1/org/outcomes?days=14")
response=call("read_skill", {name=" Repair "})
assert(#response.versions == 10 and response.layer.installedText == "customer")
call("write_skill", {name="Repair", summary="summary", text="new", basis="check"})
body=sent("PUT", "/api/v1/skills/repair/layer")
assert(body.name == nil and body.taskId == "current" and body.origin == "external" and body.author.alias == "worker" and body.fresh == false)
local missing=registry:invoke{name="read_skill", args={name="missing"}}
assert(missing.error and missing.output:find("repair", 1, true))
local _, raw=call("search_history", {query="the words"})
sent("GET", "/api/v1/tasks/parent%2Ftask/search?limit=5&q=the%20words")
assert(raw.given == "https://human.example\nhttps://source.example\n")
_, raw=call("read_original", {eventId=" model/one "})
sent("GET", "/api/v1/tasks/parent%2Ftask/events/model%2Fone")
assert(raw.given == "" and raw.structuredContent.event.actorIsAgent)
call("remember", {scope="person", key="preference", text="fact", origin="agent", subjectId="wrong"})
body=sent("PUT", "/api/v1/facts?subjectId=person%2Fone")
assert(body.origin == "external" and body.subjectId == nil and body.author == nil)
context.origin="agent"
call("remember", {scope="org", key="policy", text="fact", origin="external"})
assert(sent("PUT", "/api/v1/facts").origin == "external")
response=call("investigation", {action="read"})
assert(response.eventId == "investigation-1" and #response.sources == 1 and response.sources[1].eventId == "human-1")
local state={question="Why?", hypotheses=json.array(), checks=json.array(), outcome={status="unknown"}}
call("investigation", {action="update", state=state})
local key=client.written.requestId
assert(client.written.kind == "message" and client.written.body == "Why?\n" and #key == 78)
call("investigation", {action="update", state=state})
assert(client.written.requestId == key and client.readBound == bound)
assert(registry:invoke{name="investigation", args={action="share"}}.error)
mode="refused"
local refused=registry:invoke{name="org_outcomes", args={}}
assert(refused.error and refused.raw.structuredContent.reason == "conflict" and refused.raw.structuredContent.response.current == 9)
mode="normal"

-- An entered worktree stages sources and preserves unrelated skill metadata.
local files={["role/agent.md"]="draft", ["skills/repair/skill.json"]='{"name":"repair","text":"old","attribution":{"url":"source"},"files":[{"name":"helper.lua","text":"return 1"}]}'}
local view={revision="rev/one", snapshot={files={{name="role/agent.md", text="published"}}}}
function view:published(path) for _,file in ipairs(self.snapshot.files) do if file.name == path then return file.text end end end
function view:list() local names={} for name in pairs(files) do names[#names+1]=name end return names end
function view:read(path) return assert(files[path]) end
function view:write(path, value) files[path]=value end
function view:set_provenance(author, origin) self.author, self.origin=author, origin end
local draft=Registry.new()
options.worktree=view
for _, descriptor in ipairs(Tools.tools(client, {taskId="current", ownerId="person/one"}, options)) do draft:add(descriptor) end
response=draft:invoke{name="my_failures", args={}}.raw.structuredContent
assert(response.layer == "draft" and response.publishedLayer == "published" and response.layerDraft)
sent("GET", "/api/v1/me/failures?days=7&revision=rev%2Fone")
before=#calls
assert(not draft:invoke{name="teach_myself", args={layer="revised", basis="evidence"}}.error)
assert(files["role/agent.md"] == "revised" and view.author.model == "known-model" and view.origin == "agent")
assert(not draft:invoke{name="write_skill", args={name="repair", text="new", basis="checked"}}.error)
local saved=json.decode(files["skills/repair/skill.json"])
assert(saved.text == "new" and saved.attribution.url == "source" and #saved.files == 1 and #calls == before)
assert(#Tools.tools(client, {taskId="current"}, {config={model={memory=false}}}) == 10)
local unmarked=Registry.new()
for _, descriptor in ipairs(Tools.tools(client, {taskId="current"})) do unmarked:add(descriptor) end
assert(unmarked:invoke{name="teach_myself", args={basis="evidence", origin="agent", author={model="forged"}}}.error)
assert(#calls == before and client.readBound == bound)
`
	file := filepath.Join(t.TempDir(), "server-tools.lua")
	if err := os.WriteFile(file, []byte(script), 0600); err != nil {
		t.Fatal(err)
	}
	binary, _ := filepath.Abs("../build/agent-lua")
	modules, _ := filepath.Abs("../lua")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if output, err := exec.CommandContext(ctx, binary, file, modules).CombinedOutput(); err != nil {
		t.Fatalf("server tool contracts failed: %v\n%s", err, output)
	}
}
