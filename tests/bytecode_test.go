package probe

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

func TestSeparateBytecodeModulesKeepLazyLoadingAndSourceExtensions(t *testing.T) {
	binary, _ := filepath.Abs("../build/agent-lua")
	directory := t.TempDir()
	compiled := filepath.Join(directory, "compiled")
	if err := os.Mkdir(compiled, 0700); err != nil {
		t.Fatal(err)
	}
	first := filepath.Join(directory, "first.lua")
	second := filepath.Join(directory, "second.lua")
	for path, body := range map[string]string{
		first:  `return {value = function() return require("second") end}`,
		second: `_G.secondLoads = (_G.secondLoads or 0) + 1; return 42`,
	} {
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if output, err := exec.Command(binary, "../compile.lua", compiled, first, second).CombinedOutput(); err != nil {
		t.Fatalf("compile modules: %v\n%s", err, output)
	}
	for _, path := range []string{first, second} {
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"first", "second"} {
		body, err := os.ReadFile(filepath.Join(compiled, name+".lua"))
		if err != nil || len(body) < 4 || string(body[:4]) != "\x1bLua" {
			t.Fatalf("invalid bytecode %s: %v", name, err)
		}
	}
	extension := filepath.Join(directory, "extension.lua")
	if err := os.WriteFile(extension, []byte(`return function(n) return n + 1 end`), 0600); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(directory, "check.lua")
	if err := os.WriteFile(script, []byte(`
package.path = arg[1] .. "/?.lua;" .. arg[2] .. "/?.lua"
assert(package.loaded.second == nil and secondLoads == nil)
local first = require("first")
assert(package.loaded.second == nil and secondLoads == nil)
assert(first.value() == 42 and first.value() == 42 and secondLoads == 1)
assert(require("extension")(41) == 42)
assert(assert(load("return 40 + 2", "new-tool", "t"))() == 42)
assert(debug.getinfo(first.value, "S").source == "@first.lua")
`), 0600); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command(binary, script, compiled, directory).CombinedOutput(); err != nil {
		t.Fatalf("load modules: %v\n%s", err, output)
	}
}

// Run the real compiled application against the existing TLS/model fixture.
func TestCompiledApplicationHTTPS(t *testing.T) {
	directory := os.Getenv("OXTORG_COMPILED_LUA_DIR")
	if directory == "" {
		t.Skip("set OXTORG_COMPILED_LUA_DIR to the native module directory")
	}
	f := newFixture(t, "tool")
	// The complete application also declares its built-in server tools.
	f.allowExtraTools = true
	binary, _ := filepath.Abs("../build/agent-lua")
	command := exec.Command(binary, filepath.Join(directory, "run.lua"), f.config, "task", t.TempDir(), t.TempDir())
	command.Env = append(os.Environ(), "PROBE_TOKEN=server-test-key", "PROBE_MODEL_KEY=model-test-key")
	output, peak, err := runObserved(command)
	if err != nil {
		t.Fatalf("compiled application: %v\n%s", err, output)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.completed || f.result != "Ready." || f.calls != 2 || f.turns != 2 {
		t.Fatalf("task did not complete: %s", output)
	}
	t.Logf("observed_peak_rss_bytes=%d", peak)
}

func TestNativeLuaModuleCanUseStaticallyLinkedAPI(t *testing.T) {
	binary := os.Getenv("OXTORG_SHARED_LIBC_TEST_HOST")
	if binary == "" {
		t.Skip("set OXTORG_SHARED_LIBC_TEST_HOST to the optional shared-libc host")
	}
	directory := t.TempDir()
	source := filepath.Join(directory, "extension.c")
	if err := os.WriteFile(source, []byte(`typedef struct lua_State lua_State;
extern const char *lua_pushstring(lua_State *, const char *);
int luaopen_extension(lua_State *L) { lua_pushstring(L, "native extension loaded"); return 1; }
`), 0600); err != nil {
		t.Fatal(err)
	}
	flags := []string{"-shared", "-fPIC"}
	if runtime.GOOS == "darwin" {
		flags = []string{"-bundle", "-undefined", "dynamic_lookup"}
	}
	flags = append(flags, source, "-o", filepath.Join(directory, "extension.so"))
	if output, err := exec.Command("cc", flags...).CombinedOutput(); err != nil {
		t.Fatalf("native module: %v\n%s", err, output)
	}
	script := filepath.Join(directory, "check.lua")
	if err := os.WriteFile(script, []byte(`package.cpath = arg[1] .. "/?.so"
assert(require("extension") == "native extension loaded")`), 0600); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command(binary, script, directory).CombinedOutput(); err != nil {
		t.Fatalf("native API: %v\n%s", err, output)
	}
}
