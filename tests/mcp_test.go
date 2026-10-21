//go:build darwin || linux || netbsd

package probe

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
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

type mcpRequest struct {
	ID     int            `json:"id"`
	Method string         `json:"method"`
	Params map[string]any `json:"params"`
}

func mcpResponse(request mcpRequest, legacy bool, generation string) map[string]any {
	response := map[string]any{"jsonrpc": "2.0", "id": request.ID}
	info := map[string]string{"name": "oxtorg-probe", "title": "Probe", "version": "test"}
	meta := map[string]any{"io.modelcontextprotocol/serverInfo": info}
	var result any
	switch request.Method {
	case "server/discover":
		if legacy {
			response["error"] = map[string]any{"code": -32601, "message": "legacy server"}
			return response
		}
		result = map[string]any{"resultType": "complete", "supportedVersions": []string{"2026-07-28"}, "_meta": meta}
	case "initialize":
		result = map[string]any{"protocolVersion": "2025-06-18", "serverInfo": info, "capabilities": map[string]any{"tools": map[string]any{}}}
	case "tools/list":
		tools := []any{map[string]any{"name": "probe.echo", "title": "Echo", "description": "Echo generation " + generation,
			"inputSchema": map[string]any{"type": "object", "properties": map[string]any{"value": map[string]any{"type": "string", "x-mcp-header": "Value"}}},
			"annotations": map[string]any{"readOnlyHint": true, "destructiveHint": false, "openWorldHint": false}}}
		if generation == "2" {
			tools = append(tools, map[string]any{"name": "extra", "description": "New tool", "inputSchema": map[string]any{"type": "object"}})
		}
		result = map[string]any{"resultType": "complete", "tools": tools, "_meta": meta}
	case "tools/call":
		args, _ := request.Params["arguments"].(map[string]any)
		result = map[string]any{"resultType": "complete", "isError": args["value"] == "fail", "_meta": meta,
			"structuredContent": map[string]any{"echo": args["value"], "configured": os.Getenv("MCP_FIXTURE_VALUE"), "isolated": os.Getenv("ASENTA_MCP_SECRET") == ""},
			"content": []any{map[string]any{"type": "text", "text": "Echo result"},
				map[string]any{"type": "resource", "resource": map[string]any{"uri": "file:///answer.txt", "mimeType": "text/plain", "blob": "YW5zd2Vy"}}}}
	default:
		response["error"] = map[string]any{"code": -32601, "message": "unknown method"}
		return response
	}
	response["result"] = result
	return response
}

func TestMCPAdapter(t *testing.T) {
	if len(os.Args) > 2 && os.Args[len(os.Args)-2] == "--" {
		legacy := os.Args[len(os.Args)-1] == "legacy"
		initialized := false
		lines := bufio.NewScanner(os.Stdin)
		for lines.Scan() {
			var request mcpRequest
			if err := json.Unmarshal(lines.Bytes(), &request); err != nil {
				fmt.Fprintln(os.Stderr, "invalid fixture request:", err)
				os.Exit(2)
			}
			if request.Method == "notifications/initialized" {
				initialized = true
				continue
			}
			if legacy && strings.HasPrefix(request.Method, "tools/") && !initialized {
				os.Exit(3)
			}
			if !legacy {
				meta, _ := request.Params["_meta"].(map[string]any)
				if meta["io.modelcontextprotocol/protocolVersion"] != "2026-07-28" {
					os.Exit(4)
				}
			}
			fmt.Fprintln(os.Stderr, "fixture request:", request.Method)
			_ = json.NewEncoder(os.Stdout).Encode(mcpResponse(request, legacy, os.Getenv("MCP_GENERATION")))
		}
		os.Exit(0)
	}
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	write := func(name string, body []byte) string {
		t.Helper()
		path := filepath.Join(directory, name)
		if err := os.WriteFile(path, body, 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	helper, _ := os.Executable()
	program := filepath.Join(directory, "oxtorg-mcp-probe")
	source, err := os.Open(helper)
	if err != nil {
		t.Fatal(err)
	}
	target, err := os.OpenFile(program, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0700)
	if err != nil {
		source.Close()
		t.Fatal(err)
	}
	digest := sha256.New()
	_, err = io.Copy(io.MultiWriter(target, digest), source)
	source.Close()
	closeErr := target.Close()
	if err != nil || closeErr != nil {
		t.Fatalf("copy fixture: %v %v", err, closeErr)
	}
	passport, _ := json.Marshal(map[string]any{"name": "oxtorg-probe", "version": "test", "protocol": "2026-07-28",
		"sha256": hex.EncodeToString(digest.Sum(nil)), "transports": []string{"stdio"}})
	write("oxtorg-mcp-probe.passport.json", passport)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request mcpRequest
		if json.NewDecoder(r.Body).Decode(&request) != nil || r.Header.Get("Authorization") != "Bearer fixture-token" ||
			r.Header.Get("Mcp-Method") != request.Method || r.Header.Get("MCP-Protocol-Version") != "2026-07-28" {
			http.Error(w, "invalid MCP request headers", 400)
			return
		}
		if request.Method == "tools/call" {
			value := "=?base64?" + base64.StdEncoding.EncodeToString([]byte("line\nbreak")) + "?="
			if r.Header.Get("Mcp-Name") != "probe.echo" || r.Header.Get("Mcp-Param-Value") != value {
				http.Error(w, "missing mirrored tool argument", 400)
				return
			}
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n")
			answer, _ := json.Marshal(mcpResponse(request, false, "1"))
			fmt.Fprintf(w, "data: %s\n\n", answer)
			w.(http.Flusher).Flush()
			// The matching RPC response must end consumption without waiting
			// for the server to close a persistent event stream.
			select {
			case <-r.Context().Done():
			case <-time.After(5 * time.Second):
			}
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(mcpResponse(request, false, "1"))
	}))
	defer server.Close()
	ca := write("ca.pem", pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}))
	entry := write("mcp.lua", []byte(`package.path = arg[1] .. "/?.lua;" .. package.path
local MCP, fs = require("mcp"), require("asenta.fs")
local directory, helper, endpoint, ca = arg[2], arg[3], arg[4], arg[5]
local options = {programDir=directory, timeoutMs=3000, maxBytes=262144, caFile=ca, mcpRoot=directory .. "/pins"}
local function spec(program, mode)
    return {alias="probe", command=program, args={"-test.run=^TestMCPAdapter$", "--", mode},
        env={MCP_GENERATION="1"}, envFrom={MCP_FIXTURE_VALUE="MCP_LOCAL_VALUE"}}
end
local own = MCP.connect(spec(directory .. "/oxtorg-mcp-probe", "modern"), options)
assert(own:report().connected, own:report().reason)
assert(#own:tools() == 1 and own:tools()[1].name == "probe.echo")
local tool = own:tools()[1]
assert(tool.class == "read" and tool.foreign == false and #tool.program == 64)
local result = tool.invoke{value="hello"}
assert(result.structuredContent.echo == "hello" and result.structuredContent.configured == "passed")
assert(result.structuredContent.isolated and result.content[2].resource.blob == "YW5zd2Vy")
assert(own:call("probe.echo", {value="fail"}).isError == true)
own:close()
local legacy = MCP.connect(spec(helper, "legacy"), options)
assert(legacy:report().connected, tostring(legacy:report().reason) .. "\n" .. legacy.child:stderr())
assert(legacy.legacy and legacy:tools()[1].class == "external" and legacy:tools()[1].foreign)
assert(legacy:call("probe.echo", {value="old"}).structuredContent.echo == "old")
legacy:close()
local foreign = spec(helper, "modern")
local first = MCP.connect(foreign, options)
assert(first:report().connected, first:report().reason)
assert(first:tools()[1].description == "Echo generation 1")
first:close()
foreign.env.MCP_GENERATION = "2"
local changed = MCP.connect(foreign, options)
assert(changed:report().connected, changed:report().reason)
assert(#changed:tools() == 1 and #changed:report().held == 2)
assert(changed:tools()[1].description == "Echo generation 1")
changed:close()
local accepted = require("desktop").accept_tools(options.mcpRoot, "probe")
assert(#accepted == 2 and accepted[1] == "extra" and accepted[2] == "probe.echo")
local reread = MCP.connect(foreign, options)
assert(reread:report().connected, reread:report().reason)
assert(#reread:report().held == 0 and #reread:tools() == 2)
local found = false
for _, offered in ipairs(reread:tools()) do
    if offered.name == "probe.echo" then
        assert(offered.description == "Echo generation 2")
        assert(offered.class == "external" and offered.foreign)
        found = true
    end
end
assert(found, "accepted declaration did not reach the registry")
reread:close()
local missing = spec(helper, "modern")
missing.envFrom = {KEY="MCP_ABSENT_VALUE"}
local absent = MCP.connect(missing, options)
assert(not absent:report().connected and absent:report().missing[1] == "MCP_ABSENT_VALUE")
absent:close()
local remote = MCP.connect({alias="remote", url=endpoint, tokenEnv="MCP_HTTP_TOKEN", own=true}, options)
assert(remote:report().connected, remote:report().reason)
assert(remote:tools()[1].name == "remote/probe.echo")
assert(remote:tools()[1].invoke{value="line\nbreak"}.structuredContent.echo == "line\nbreak")
remote:close()
local root = assert(fs.root(directory, false))
assert(root:write("oxtorg-mcp-probe.passport.json", '{"name":"oxtorg-probe","sha256":"wrong"}'))
root:close()
local replaced = MCP.connect(spec(directory .. "/oxtorg-mcp-probe", "modern"), options)
assert(not replaced:report().connected and replaced:report().reason:find("SHA256"))
replaced:close()
print("mcp-ok")
`))
	binary, _ := filepath.Abs("../build/agent-lua")
	modules, _ := filepath.Abs("../lua")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, entry, modules, directory, helper, server.URL, ca)
	cmd.Env = append(os.Environ(), "MCP_LOCAL_VALUE=passed", "MCP_HTTP_TOKEN=fixture-token", "ASENTA_MCP_SECRET=parent-secret")
	output, err := cmd.CombinedOutput()
	if err != nil || string(output) != "mcp-ok\n" {
		t.Fatalf("MCP adapter: %v\n%s", err, output)
	}
}
