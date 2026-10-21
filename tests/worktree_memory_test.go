package probe

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The server streams a corpus larger than the process's intended Lua heap.
// No fixture or client constructs the complete snapshot response in memory.
func TestWorktreeReadsSelectedFilesWithBoundedMemory(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/me/worktree":
			fmt.Fprint(w, `{"workspaceId":"org","worktreeId":"tree","revision":"r1"}`)
		case "/api/v1/me/worktree/snapshot":
			fmt.Fprint(w, `{"workspaceId":"org","files":[{"name":"notebook/index.md","text":"# Index\n"},{"name":"role/agent.md","text":"Use evidence."}`)
			for n := 0; n < 192; n++ {
				entry, _ := json.Marshal(map[string]string{"name": fmt.Sprintf("notebook/note-%03d.md", n), "text": fmt.Sprintf("# Reference %d\n", n) + strings.Repeat("Technical reference information. ", 2000)})
				fmt.Fprintf(w, ",%s", entry)
			}
			fmt.Fprint(w, `],"revision":"r1","worktreeId":"tree"}`)
		case "/api/v1/me/worktree/search":
			fmt.Fprint(w, `{"revision":"r1","result":{"hits":[{"path":"note-007.md"}]}}`)
		default:
			t.Errorf("unexpected request: %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	directory := t.TempDir()
	script := filepath.Join(directory, "memory.lua")
	if err := os.WriteFile(script, []byte(worktreeMemoryScenario), 0600); err != nil {
		t.Fatal(err)
	}
	modules, _ := filepath.Abs("../lua")
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "../build/agent-lua", script, directory, modules, server.URL)
	cmd.Env = append(os.Environ(), "OXTORG_WORKTREE=")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("bounded worktree: %v\n%s", err, out)
	}
	t.Log(string(out))
}

const worktreeMemoryScenario = `
package.path=arg[2].."/?.lua;"..package.path
local Worktree,Client,core=require("worktree"),require("client"),require("asenta.core")
local config={worktreeRoot=arg[1].."/cache",server={baseUrl=arg[3]},model={alias="writer"}}
local identity={organization={orgId="org"},user={userId="agent"}}
local manager=Worktree.new(config,Client.new(config),identity)
local view=assert(manager:enter("task","owner"))
assert(#view:list()==194)
local cold=core.stats()
assert(cold.luaPeakBytes<4*1024*1024,"cold snapshot retained source bodies: "..cold.luaPeakBytes)
view=nil
collectgarbage("collect")
local count=0
local read=manager._read
manager._read=function(self,ref) if ref then count=count+1 end;return read(self,ref) end
view=assert(manager:enter("task","owner","r1"))
assert(count==2,"enter read more than the selected role and index")
assert(view:status()=="")
local found=view:search("reference",1)
assert(count==2,"server search loaded the local corpus")
assert(view:read("notebook/"..found.hits[1].path):find("Reference 7",1,true))
assert(count==3,"read fetched unrelated files")
view:write("notebook/new.md","# New\nSelected draft.\n")
assert(count==4,"write loaded unchanged sources")
assert(#view:diff({"notebook/new.md"})==1)
local saved=assert(manager:_root():stat(view.attempt))
assert(saved.size<256*1024,"draft contains source bodies")
collectgarbage("collect")
local after=core.stats()
assert(after.luaBytes<2*1024*1024,"retained heap scales with corpus bytes")
local bytes=0
for _,file in ipairs(view.snapshot.files) do bytes=bytes+manager:_size(file.blob) end
print(require("json").encode({files=194,sourceBytes=bytes,coldLuaPeak=cold.luaPeakBytes,retainedLua=after.luaBytes,draftBytes=saved.size}))
manager:close()
`
