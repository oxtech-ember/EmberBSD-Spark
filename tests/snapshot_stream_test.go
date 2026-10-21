package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestSnapshotStreamReleasesFilesAndRejectsIncompleteInput(t *testing.T) {
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(directory, "snapshot-stream.lua")
	if err := os.WriteFile(script, []byte(snapshotStreamScenario), 0600); err != nil {
		t.Fatal(err)
	}
	modules, err := filepath.Abs("../lua")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if output, err := exec.CommandContext(ctx, "../build/agent-lua", script, modules).CombinedOutput(); err != nil {
		t.Fatalf("streamed snapshot: %v\n%s", err, output)
	}
}

const snapshotStreamScenario = `
package.path=arg[1] .. "/?.lua;" .. package.path
local json,Stream=require("json"),require("snapshot_stream")
local function feed(parser,body,width)
  for at=1,#body,width do parser:feed(body:sub(at,at+width-1)) end
end
local received,expected=0,nil
local weak=setmetatable({}, {__mode="v"})
local parser=Stream.new(function(file)
  received=received+1
  assert(file.name=="notebook/file-" .. received .. ".md" and file.text==expected)
  weak[1]=file
end)
-- The whole fixture exceeds 12 MiB, but neither its producer nor the parser
-- constructs the complete body. Files precede the binding metadata.
parser:feed('{"files":[')
collectgarbage("collect")
local baseline=collectgarbage("count")
for index=1,768 do
  if index>1 then parser:feed(",") end
  expected=string.rep("source [ } ",1500) .. "\n" .. index .. " \195\169 \240\159\148\167 \" \\"
  local wire=json.encode({name="notebook/file-" .. index .. ".md",text=expected})
  feed(parser,wire,113)
  if index%128==0 then
    collectgarbage("collect")
    assert(weak[1]==nil,"parser retained a decoded file after its callback")
    assert(collectgarbage("count")-baseline<2048,"parser retained earlier file JSON")
  end
end
feed(parser,'],"revision":"r1","name":"Shared", "workspaceId":"org","worktreeId":"tree",' ..
  '"extra":{"array":[true,false,null,{"quoted":"} ]"}]},"number":12,"flag":false}',1)
local metadata=parser:finish()
assert(received==768 and metadata.files==nil and metadata.revision=="r1" and metadata.workspaceId=="org")
assert(metadata.worktreeId=="tree" and metadata.name=="Shared" and metadata.number==12 and metadata.flag==false)
assert(metadata.extra.array[3]==json.null and metadata.extra.array[4].quoted=="} ]")

-- Every UTF-8 byte, escape, surrogate pair and structural token can be split.
local escaped='{"text":"raw \195\169 \\uD83D\\uDD27 \\\" } ] \\n tail","name":"notebook/escaped.md"}'
local wanted=json.decode(escaped)
local count=0
local boundary=Stream.new(function(file) count=count+1;assert(file.name==wanted.name and file.text==wanted.text) end)
feed(boundary,'{"name":"First","files":[' .. escaped .. '],"revision":"last"}',1)
assert(boundary:finish().revision=="last" and count==1)

local valid='{"name":"notebook/a.md","text":"valid"}'
for _,body in ipairs({
  '{"files":[{"name":"notebook/a.md","text":"truncated',
  '{"files":[' .. valid .. '],"revision":',
  '{"files":[' .. valid .. ',]}',
  '{"files":[],"files":[]}',
  '{"files":[]} trailing',
  '{"files":null}',
  '{"files":[{"name":"notebook/a.md","text":"\\q"}]}',
  '{"files":[{"name":"notebook/a.md"}]}',
  '{}'
}) do
  local seen=0
  local broken=Stream.new(function() seen=seen+1 end)
  assert(not pcall(function() feed(broken,body,7);broken:finish() end),"accepted malformed or incomplete snapshot")
  assert(seen<=1,"a file callback was repeated after invalid input")
end
local boundCalls=0
local bounded=Stream.new(function() boundCalls=boundCalls+1 end)
bounded:feed('{"files":[{"name":"notebook/large.md","text":"')
local block=string.rep("x",65536)
assert(not pcall(function() for _=1,98 do bounded:feed(block) end end),"unbounded current file JSON")
assert(boundCalls==0)
local thrown=Stream.new(function() error("storage failed") end)
assert(not pcall(thrown.feed,thrown,'{"files":[' .. valid .. ']}'))
assert(not pcall(thrown.feed,thrown,'{"files":[]}'),"continued after a failed callback")
`
