package probe

import (
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
)

type fixture struct {
	mu                         sync.Mutex
	config, scenario, result   string
	version, turns, calls      int
	completed, disconnected    bool
	historyPages, historyReads int
	requests                   map[string]bool
	checkStarts                bool
	modelStarts                int
	paidRecords                int
	allowExtraTools            bool
}

func newFixture(t *testing.T, scenario string) *fixture {
	t.Helper()
	f := &fixture{scenario: scenario, version: 1, requests: map[string]bool{}}
	server := httptest.NewUnstartedServer(http.HandlerFunc(f.serve))
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.StartTLS()
	t.Cleanup(server.Close)
	dir := t.TempDir()
	write := func(name string, data []byte) string {
		t.Helper()
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	ca := write("ca.pem", pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}))
	if scenario == "untrusted" {
		ca = ""
	}
	write("role.md", []byte("Answer briefly. Use decode_code when asked to decode a code."))
	tool, _ := filepath.Abs("../examples/decode_code.lua")
	if scenario == "tool-encoding-error" {
		tool = write("unencodable.lua", []byte("return function() return function() end end"))
	}
	cfg := map[string]any{
		"name": "c-lua-probe", "roleFile": "role.md",
		"server":    map[string]string{"baseUrl": server.URL, "tokenEnv": "PROBE_TOKEN"},
		"model":     map[string]string{"baseUrl": server.URL, "keyEnv": "PROBE_MODEL_KEY", "alias": "test-model"},
		"limits":    map[string]int{"maxTurns": 4},
		"transport": map[string]any{"caFile": ca, "timeoutMs": 3000, "maxBytes": 131072},
		"luaTools": []any{map[string]any{"name": "decode_code", "description": "Decode a diagnostic code", "file": tool,
			"parameters": map[string]any{"type": "object", "properties": map[string]any{"code": map[string]string{"type": "string"}}, "required": []string{"code"}}}},
	}
	body, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	f.config = write("agent.json", body)
	return f
}

func (f *fixture) task() map[string]any {
	state := "working"
	if f.completed {
		state = "completed"
	}
	return map[string]any{"taskId": "task", "kind": "errand", "state": state, "assigneeId": "executor", "ownerId": "person", "budgetLeft": 100000, "version": f.version}
}

func (f *fixture) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	token := "server-test-key"
	if strings.HasPrefix(r.URL.Path, "/v1/") {
		token = "model-test-key"
	}
	if r.Header.Get("Authorization") != "Bearer "+token {
		http.Error(w, "wrong credential", 401)
		return
	}
	if f.scenario == "read-disconnect" && r.Method == "GET" && !f.disconnected {
		f.disconnected = true
		conn, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			conn.Close()
		}
		return
	}
	w.Header().Set("Content-Type", "application/json")
	var out any
	switch r.URL.Path {
	case "/v1/models":
		out = map[string]any{"data": []any{}}
	case "/api/v1/tasks":
		out = map[string]any{"tasks": []any{f.task()}}
	case "/api/v1/me/worktree":
		http.Error(w, `{"reason":"not_found"}`, 404)
		return
	case "/api/v1/me/role":
		out = map[string]any{"role": map[string]int{"version": 1}}
	case "/api/v1/me/rig":
		out = map[string]any{"rig": []any{}}
	case "/api/v1/skills", "/api/v1/tasks/task/skills":
		out = map[string]any{"skills": []any{}}
	case "/api/v1/tasks/task/attachments":
		out = map[string]any{"attachments": []any{}}
	case "/api/v1/me/tools":
		out = map[string]bool{"ok": true}
	case "/api/v1/me":
		out = map[string]any{"user": map[string]string{"userId": "executor", "kind": "agent"}, "organization": map[string]string{"orgId": "organisation"}}
	case "/api/v1/tasks/task", "/api/v1/tasks/task/lease":
		out = map[string]any{"task": f.task()}
	case "/api/v1/tasks/task/events":
		if r.Method == "GET" {
			if f.historyPages > 0 {
				after, err := strconv.Atoi(r.URL.Query().Get("after"))
				if err != nil || after < 0 || after >= f.historyPages {
					http.Error(w, "invalid history cursor", 400)
					return
				}
				cursor := after + 1
				f.historyReads++
				out = map[string]any{"events": []any{map[string]any{"eventId": fmt.Sprint(cursor), "cursor": cursor,
					"kind": "message", "actorId": "person", "body": historyBody(cursor)}}, "cursor": cursor, "hasMore": cursor < f.historyPages}
				break
			}
			out = map[string]any{"events": []any{map[string]any{"eventId": "message", "cursor": 1, "kind": "message", "actorId": "person", "body": "Decode 0133."}}, "cursor": 1, "hasMore": false}
			break
		}
		var event map[string]any
		if json.NewDecoder(r.Body).Decode(&event) != nil {
			http.Error(w, "invalid event", 400)
			return
		}
		if event["version"] != float64(f.version) || event["requestId"] == "" || event["requestId"] == nil {
			http.Error(w, "missing request key or stale version", 409)
			return
		}
		key := event["requestId"].(string)
		if f.requests[key] {
			http.Error(w, "duplicate event", 409)
			return
		}
		f.requests[key] = true
		if event["title"] == "thinking" && event["phase"] == "start" {
			f.modelStarts++
		}
		if event["units"] == float64(15) {
			f.paidRecords++
		}
		if event["title"] == "decode_code" {
			f.calls++
		}
		if event["kind"] == "result" {
			f.result, _ = event["body"].(string)
			f.completed = event["state"] == "completed" && event["readUpTo"] == float64(max(1, f.historyPages))
		}
		f.version++
		out = map[string]any{"event": map[string]any{"eventId": fmt.Sprint(f.version)}, "version": f.version}
	case "/v1/responses":
		if f.checkStarts && f.modelStarts != f.turns+1 {
			http.Error(w, "model called before its start was recorded", 409)
			return
		}
		var input struct {
			Store bool `json:"store"`
			Tools []struct {
				Name string `json:"name"`
			} `json:"tools"`
			Input []struct {
				Type, Output, Role string
				Content            any
				CallID             string `json:"call_id"`
			} `json:"input"`
		}
		if json.NewDecoder(r.Body).Decode(&input) != nil || input.Store {
			http.Error(w, "invalid model request", 400)
			return
		}
		f.turns++
		if f.historyPages > 0 {
			if len(input.Input) != f.historyPages+1 {
				http.Error(w, "history pages lost", 400)
				return
			}
			for cursor := 1; cursor <= f.historyPages; cursor++ {
				if input.Input[cursor].Role != "user" || input.Input[cursor].Content != historyBody(cursor) {
					http.Error(w, "history content changed", 400)
					return
				}
			}
		}
		tool := strings.HasPrefix(f.scenario, "tool") || f.scenario == "cut"
		output := []any{map[string]any{"type": "message", "role": "assistant", "content": []any{map[string]string{"type": "output_text", "text": "Ready."}}}}
		status := "completed"
		if f.turns == 1 && tool {
			declared := false
			for _, item := range input.Tools {
				declared = declared || item.Name == "decode_code"
			}
			if !declared || (!f.allowExtraTools && len(input.Tools) != 1) {
				http.Error(w, "missing tool declaration", 400)
				return
			}
			args := `{"code":"0133"}`
			if f.scenario == "tool-error" {
				args = `{"code":"not-hex"}`
			}
			output = []any{map[string]string{"type": "function_call", "call_id": "call-1", "name": "decode_code", "arguments": args}}
			if f.scenario == "cut" {
				status = "incomplete"
			}
		} else if tool {
			found := false
			for _, item := range input.Input {
				if item.Type != "function_call_output" || item.CallID != "call-1" {
					continue
				}
				found = (f.scenario == "tool" && item.Output == "P0133") || (f.scenario != "tool" && strings.Contains(item.Output, "error"))
			}
			if !found {
				http.Error(w, "tool result or call id lost", 400)
				return
			}
		}
		out = map[string]any{"status": status, "output": output, "usage": map[string]int{"input_tokens": 10, "output_tokens": 5, "total_tokens": 15}}
	default:
		http.Error(w, "unexpected route", 404)
		return
	}
	json.NewEncoder(w).Encode(out)
}

func historyBody(cursor int) string {
	return fmt.Sprintf("Page %d. ", cursor) + strings.Repeat("Diagnostic context. ", 2048)
}
