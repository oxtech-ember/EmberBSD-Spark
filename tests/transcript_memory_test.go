package probe

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Historical text stays in disk records through authority/context preparation
// and the actual HTTP request. The server checks the complete transmitted data.
func TestTranscriptStreamsHistoryAndModelInput(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/tasks/task/events":
			fmt.Fprint(w, `{"events":[`)
			for n := 0; n < 180; n++ {
				if n > 0 {
					fmt.Fprint(w, ",")
				}
				body := fmt.Sprintf("Recorded item %d: ", n) + strings.Repeat("Observed telemetry. ", 3200)
				row, _ := json.Marshal(map[string]any{"kind": "message", "eventId": fmt.Sprint(n), "cursor": n + 1, "actorId": "owner", "body": body})
				w.Write(row)
			}
			fmt.Fprint(w, `],"cursor":180,"hasMore":false}`)
		case "/v1/models":
			io.WriteString(w, `{"data":[{"id":"fixture","metadata":{"context_window":2000000}}]}`)
		case "/v1/responses":
			var request struct {
				Input []struct {
					Role    string `json:"role"`
					Content string `json:"content"`
				} `json:"input"`
				Tools []struct {
					Type        string `json:"type"`
					Name        string `json:"name"`
					Description string `json:"description"`
				} `json:"tools"`
			}
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				t.Error(err)
				w.WriteHeader(400)
				return
			}
			if len(request.Input) != 182 {
				t.Errorf("input count %d", len(request.Input))
			}
			if request.Input[0].Content != strings.Repeat("Use measured evidence. ", 4000) || len(request.Tools) != 64 {
				t.Errorf("role or tool catalogue changed")
			}
			for n, tool := range request.Tools {
				if tool.Type != "function" || tool.Name != fmt.Sprintf("read_%02d", n+1) || tool.Description != strings.Repeat("Read the selected measurement. ", 1200) {
					t.Errorf("tool %d lost its declaration", n)
				}
			}
			for n, row := range request.Input[2:] {
				if !strings.Contains(row.Content, fmt.Sprintf("Recorded item %d:", n)) || len(row.Content) < 64000 {
					t.Errorf("input %d lost text", n)
				}
			}
			io.WriteString(w, `{"output":[{"type":"message","content":[{"type":"output_text","text":"Accepted."}]}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}`)
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	directory := t.TempDir()
	script := filepath.Join(directory, "transcript.lua")
	if err := os.WriteFile(script, []byte(transcriptMemoryScenario), 0600); err != nil {
		t.Fatal(err)
	}
	modules, _ := filepath.Abs("../lua")
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "../build/agent-lua", script, directory, modules, server.URL)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("transcript memory: %v\n%s", err, out)
	}
	t.Log(string(out))
}

const transcriptMemoryScenario = `
package.path=arg[2].."/?.lua;"..package.path
local Client,Context,Sequence=require("client"),require("context"),require("sequence")
local fs,core=require("asenta.fs"),require("asenta.core")
local root=assert(fs.root(arg[1],false))
local config={server={baseUrl=arg[3]},model={alias="fixture",baseUrl=arg[3]}}
local client=Client.new(config):for_task("task")
local history=client:history(root)
assert(Sequence.is(history) and #history==180 and client.readUpTo==180)
local task={taskId="task",assigneeId="agent",title="Report observations"}
local registry=require("registry").new{root=root}
for i=1,64 do registry:add{name=string.format("read_%02d",i),class="read",invoke=function()end,
    description=string.rep("Read the selected measurement. ",1200),parameters={type="object"}} end
local options=Sequence.fields(root,{root=root,actorId="agent",role=string.rep("Use measured evidence. ",4000),registry=registry},{"role"})
local prepared=Context.prepare(task,history,options)
assert(Sequence.is(prepared.input))
local chain=require("provenance").new{task=task,history=history,registry=registry,actorId="agent"}
assert(#chain.state.given<1024)
local definitions=registry:definitions()
assert(Sequence.is(definitions) and rawget(registry:find("read_01"),"description")==nil)
local counted=Context.measure(prepared,definitions, {contextWindow=0},0)
assert(counted.occupied>1000000)
local result=require("model").new(config,client):request(prepared.input,definitions)
assert(result.answer=="Accepted.")
collectgarbage("collect")
local memory=core.stats()
assert(memory.luaPeakBytes<4*1024*1024,"history or wire request was materialized: "..memory.luaPeakBytes)
assert(memory.luaBytes<1024*1024,"history was retained: "..memory.luaBytes)
print(require("json").encode({events=#history,luaPeak=memory.luaPeakBytes,luaRetained=memory.luaBytes}))
root:close()
`
