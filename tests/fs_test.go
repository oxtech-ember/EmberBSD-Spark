package probe

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Exercise the storage boundary through the real host. The owner process
// replaces files while this process reads them and a second host contests its
// lock; neither atomicity nor process lock ownership is mocked.
func TestConfinedFilesystem(t *testing.T) {
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(base, "state")
	outside := filepath.Join(base, "outside")
	for _, dir := range []string{root, outside} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(outside, "keep"), []byte("outside"), 0600); err != nil {
		t.Fatal(err)
	}
	for name, target := range map[string]string{"outside": outside, "linked": filepath.Join(outside, "keep")} {
		if err := os.Symlink(target, filepath.Join(root, name)); err != nil {
			t.Fatal(err)
		}
	}
	binary, err := filepath.Abs("../build/agent-lua")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	script := func(name, source string) string {
		t.Helper()
		path := filepath.Join(base, name+".lua")
		if err := os.WriteFile(path, []byte(source), 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	check := script("check", `
local fs = require("asenta.fs")
local root = assert(fs.root(arg[1], false))
assert(fs.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
assert(root:mkdir("notes/deep"))
local trusted = assert(fs.root(arg[1] .. "/notes/../notes/", false))
assert(trusted:close())
assert(root:write("notes/deep/note.md", "old\0bytes"))
assert(root:read("notes/deep/note.md", 9) == "old\0bytes")
assert(root:hash("notes/deep/note.md") == fs.sha256("old\0bytes"))
local body, why = root:read("notes/deep/note.md", 8)
assert(body == nil and why:find("limit"))
for _, path in ipairs({"/absolute", "../escape", "notes/../escape", "a//b", "a/./b", "a/", "a\\b", "a\0b"}) do
  assert(not pcall(root.write, root, path, "changed"), path)
end
assert(not root:write("notes/deep", "changed"))
assert(root:read("notes/deep/note.md") == "old\0bytes")
assert(not root:read("outside/keep"))
assert(not root:read("linked"))
assert(not root:hash("linked"))
assert(not root:write("outside/keep", "changed"))
assert(not root:write("linked", "changed"))
assert(not root:mkdir("outside/new"))
assert(root:stat("linked").kind == "symlink")
local entries = {}
for _, entry in ipairs(assert(root:list())) do entries[entry.name] = entry end
assert(entries.outside.kind == "symlink" and entries.notes.kind == "directory")
assert(root:rename("notes/deep/note.md", "notes/deep/renamed.md"))
assert(root:stat("notes/deep/note.md") == nil)
assert(root:stat("notes/deep/renamed.md").size == 9)
assert(not root:remove("notes/deep"))
assert(root:remove("notes/deep/renamed.md"))
assert(root:remove("notes/deep"))
assert(root:remove("linked"))
assert(root:close())
assert(root:close())
assert(not pcall(root.read, root, "notes/deep/renamed.md"))
`)
	if out, err := exec.CommandContext(ctx, binary, check, root).CombinedOutput(); err != nil {
		t.Fatalf("filesystem contract: %v\n%s", err, out)
	}
	if data, err := os.ReadFile(filepath.Join(outside, "keep")); err != nil || string(data) != "outside" {
		t.Fatalf("outside content changed: %q %v", data, err)
	}
	owner := script("owner", `
local fs = require("asenta.fs")
local root = assert(fs.root(arg[1], false))
local lock = assert(root:lock("agent.lock"))
local a, b = string.rep("a", 65536), string.rep("b", 65536)
assert(root:write("atomic", a))
io.write("ready\n"); io.flush()
assert(io.read("*l") == "write")
for i = 1, 32 do assert(root:write("atomic", i % 2 == 0 and a or b)) end
io.write("written\n"); io.flush()
assert(io.read("*l") == "close")
assert(root:close())
assert(lock:close())
`)
	contender := script("contender", `
local root = assert(require("asenta.fs").root(arg[1], false))
local lock, why = root:lock("agent.lock")
if arg[2] == "busy" then
  assert(lock == nil and why == "busy", tostring(why))
else
  assert(lock, why)
  assert(lock:close())
end
`)
	cmd := exec.CommandContext(ctx, binary, owner, root)
	var diagnostics bytes.Buffer
	cmd.Stderr = &diagnostics
	input, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	output, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()
	reader := bufio.NewReader(output)
	if line, err := reader.ReadString('\n'); err != nil || line != "ready\n" {
		t.Fatalf("owner did not start: %q %v", line, err)
	}
	if out, err := exec.CommandContext(ctx, binary, contender, root, "busy").CombinedOutput(); err != nil {
		t.Fatalf("contested lock: %v\n%s", err, out)
	}
	if _, err := fmt.Fprintln(input, "write"); err != nil {
		t.Fatal(err)
	}
	finished := make(chan error, 1)
	go func() {
		line, err := reader.ReadString('\n')
		if err == nil && line != "written\n" {
			err = fmt.Errorf("unexpected owner output %q", line)
		}
		finished <- err
	}()
	a, b := strings.Repeat("a", 65536), strings.Repeat("b", 65536)
	for observing := true; observing; {
		select {
		case err := <-finished:
			if err != nil {
				t.Fatal(err)
			}
			observing = false
		default:
			body, err := os.ReadFile(filepath.Join(root, "atomic"))
			if err != nil || (string(body) != a && string(body) != b) {
				t.Fatalf("observed a partial atomic write: bytes=%d error=%v", len(body), err)
			}
		}
	}
	if _, err := fmt.Fprintln(input, "close"); err != nil {
		t.Fatal(err)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("owner failed: %v\n%s", err, diagnostics.String())
	}
	if out, err := exec.CommandContext(ctx, binary, contender, root, "acquire").CombinedOutput(); err != nil {
		t.Fatalf("released lock remained busy: %v\n%s", err, out)
	}
	info, err := os.Stat(filepath.Join(root, "atomic"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("written file is not private: %v %v", info, err)
	}
}
