package probe

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// Exercise the delivered files with no source-tree or installed Lua modules.
// The TLS fixture supplies both server and model; no external service is used.
func TestNativePackageRelocation(t *testing.T) {
	source := os.Getenv("OXTORG_NATIVE_AGENT_BUNDLE")
	if source == "" {
		t.Skip("set OXTORG_NATIVE_AGENT_BUNDLE to a build.sh output directory")
	}
	directory := filepath.Join(t.TempDir(), "relocated package")
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"oxtorg-agent", "oxtorg-agent.lua", "BUILD"} {
		body, err := os.ReadFile(filepath.Join(source, name))
		if err != nil {
			t.Fatal(err)
		}
		mode := os.FileMode(0600)
		if name == "oxtorg-agent" {
			mode = 0700
		}
		if err := os.WriteFile(filepath.Join(directory, name), body, mode); err != nil {
			t.Fatal(err)
		}
	}
	directory, err := filepath.EvalSymlinks(directory)
	if err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(directory, "oxtorg-agent")
	working := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	environment := []string{}
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if name != "LUA_PATH" && name != "LUA_CPATH" && name != "OXTORG_AGENT_BUILD" && name != "OXTORG_SUPERVISED" {
			environment = append(environment, entry)
		}
	}
	environment = append(environment, "LUA_PATH=/unavailable/?.lua", "LUA_CPATH=/unavailable/?.so", "OXTORG_AGENT_BUILD=wrong-build", "PROBE_TOKEN=server-test-key", "PROBE_MODEL_KEY=model-test-key")
	run := func(arguments ...string) []byte {
		t.Helper()
		command := exec.CommandContext(ctx, binary, arguments...)
		command.Dir, command.Env = working, environment
		body, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("native package %v: %v\n%s", arguments, err, body)
		}
		return body
	}
	version, err := os.ReadFile(filepath.Join(directory, "BUILD"))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(run("-version"))); got != strings.TrimSpace(string(version)) {
		t.Fatalf("package version %q differs from BUILD %q", got, version)
	}
	var capabilities []struct{ Environment, Version string }
	if err := json.Unmarshal(run("-capabilities"), &capabilities); err != nil {
		t.Fatal(err)
	}
	if len(capabilities) == 0 || capabilities[0].Environment != "native" || capabilities[0].Version != strings.TrimSpace(string(version)) {
		t.Fatalf("native package capabilities: %+v", capabilities)
	}

	// An explicit script retains the interpreter interface, including arg[0].
	// Ordinary require can still load installation-owned native Lua modules.
	moduleSource := filepath.Join(working, "fixture.c")
	if err := os.WriteFile(moduleSource, []byte(`typedef struct lua_State lua_State;
extern const char *lua_pushstring(lua_State *, const char *);
int luaopen_fixture(lua_State *L) { lua_pushstring(L, "native module loaded"); return 1; }
`), 0600); err != nil {
		t.Fatal(err)
	}
	moduleFlags := []string{"-shared", "-fPIC"}
	if runtime.GOOS == "darwin" {
		moduleFlags = []string{"-bundle", "-undefined", "dynamic_lookup"}
	}
	moduleFlags = append(moduleFlags, moduleSource, "-o", filepath.Join(working, "fixture.so"))
	if output, err := exec.CommandContext(ctx, "cc", moduleFlags...).CombinedOutput(); err != nil {
		t.Fatalf("build native module fixture: %v\n%s", err, output)
	}
	script := filepath.Join(working, "contract.lua")
	code := `assert(arg[0]:match("contract.lua$")); assert(arg[1] == "kept")
assert(require("asenta.core").programDir == arg[2])
package.cpath = arg[4] .. "/?.so"
assert(require("fixture") == "native module loaded")
local fs = require("asenta.fs")
assert(fs.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
local root = assert(fs.root(arg[3], true))
assert(root:write("data", "abc"))
assert(root:hash("data") == fs.sha256("abc"))
assert(root:close())
`
	if err := os.WriteFile(script, []byte(code), 0600); err != nil {
		t.Fatal(err)
	}
	run(script, "kept", directory, filepath.Join(working, "files"), working)

	f := newFixture(t, "answer")
	data, err := os.ReadFile(f.config)
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]any
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	server := config["server"].(map[string]any)
	endpoint := server["baseUrl"].(string)
	server["baseUrl"] = "https://127.0.0.1:1"
	data, err = json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(f.config, data, 0600); err != nil {
		t.Fatal(err)
	}
	run("-config", f.config, "-server", endpoint, "--state-root", filepath.Join(working, "state"), "--once")
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.completed || f.turns != 1 || f.result != "Ready." {
		t.Fatalf("relocated application did not finish its fixture task: completed=%v, turns=%d, result=%s", f.completed, f.turns, f.result)
	}
}
