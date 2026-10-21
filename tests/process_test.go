//go:build darwin || linux || netbsd

package probe

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The test executable is also the child: no shell, interpreter or external
// service is needed to exercise real pipes, inherited descriptors and groups.
func TestNativeProcess(t *testing.T) {
	if len(os.Args) > 2 && os.Args[len(os.Args)-2] == "--" {
		processHelper(os.Args[len(os.Args)-1])
		os.Exit(0)
	}
	t.Setenv("ASENTA_PROCESS_SECRET", "private-parent-value")
	directory := t.TempDir()
	// getcwd in the child returns the physical path (macOS aliases /var).
	directory, err := filepath.EvalSymlinks(directory)
	if err != nil {
		t.Fatal(err)
	}
	explicit, automatic := filepath.Join(directory, "explicit"), filepath.Join(directory, "automatic")
	for _, dir := range []string{explicit, automatic} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			pids, _ := os.ReadFile(filepath.Join(dir, "pids"))
			for _, value := range strings.Fields(string(pids)) {
				if pid, _ := strconv.Atoi(value); pid > 0 {
					_ = syscall.Kill(pid, syscall.SIGKILL)
				}
			}
		})
	}
	script := `local process = require("asenta.process")
local helper, cwd, explicit, automatic = arg[1], arg[2], arg[3], arg[4]
local function command(mode)
    return {helper, "-test.run=^TestNativeProcess$", "--", mode}
end
local child = process.spawn{argv=command("echo"), cwd=cwd,
    env={ASENTA_PROCESS_VALUE="exact"}, stderrBytes=512, stdoutBytes=512*1024}
assert(child:status() == nil)
local payload = string.rep("x", 128*1024)
assert(child:send(payload .. "\n", 5000))
assert(child:receive(5000, 4096) == "ready|exact||" .. cwd)
assert(child:receive(5000, #payload) == payload)
local diagnostic = child:stderr()
assert(#diagnostic == 512 and diagnostic:sub(-13) == "[stderr-end]\n")
local absent, reason = child:receive(25, 4096)
assert(absent == nil and reason == "timeout")
assert(child:send("tail\n", 5000))
assert(child:receive(5000, 4096) == "incomplete-tail")
absent, reason = child:receive(5000, 4096)
assert(absent == nil and reason == "eof")
child:close()
assert(child:status() == 0)
assert(child:stderr():sub(-13) == "[stderr-end]\n")
local inherited = process.spawn{argv=command("environment")}
assert(inherited:receive(5000, 4096) == "private-parent-value")
inherited:close()
local tree = process.spawn{argv=command("tree"), env={ASENTA_PROCESS_TREE=explicit}}
assert(tree:receive(5000, 4096) == "tree-ready")
tree:close()
assert(tree:status() == 0)
local stubborn = process.spawn{argv=command("stubborn")}
assert(stubborn:receive(5000, 4096) == "stubborn-ready")
stubborn:close()
assert(stubborn:status() == 128 + 9)
local orphan = process.spawn{argv=command("tree"), env={ASENTA_PROCESS_TREE=automatic}}
assert(orphan:receive(5000, 4096) == "tree-ready")
print("process-ok")
`
	entry := filepath.Join(directory, "process.lua")
	if err := os.WriteFile(entry, []byte(script), 0600); err != nil {
		t.Fatal(err)
	}
	binary, err := filepath.Abs("../build/agent-lua")
	if err != nil {
		t.Fatal(err)
	}
	helper, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, entry, helper, directory, explicit, automatic)
	output, err := cmd.CombinedOutput()
	if err != nil || string(output) != "process-ok\n" {
		t.Fatalf("process contract: %v\n%s", err, output)
	}
	for _, dir := range []string{explicit, automatic} {
		for _, marker := range []string{"leader-stopped", "child-stopped"} {
			if _, err := os.Stat(filepath.Join(dir, marker)); err != nil {
				t.Fatalf("process group did not stop (%s): %v", dir, err)
			}
		}
		pids, err := os.ReadFile(filepath.Join(dir, "pids"))
		if err != nil {
			t.Fatal(err)
		}
		for _, value := range strings.Fields(string(pids)) {
			pid, err := strconv.Atoi(value)
			if err != nil || syscall.Kill(pid, 0) != syscall.ESRCH {
				t.Fatalf("child %q survived process cleanup", value)
			}
		}
		if err := os.Remove(filepath.Join(dir, "pids")); err != nil {
			t.Fatal(err)
		}
	}
}

func processHelper(mode string) {
	switch mode {
	case "echo":
		cwd, _ := os.Getwd()
		fmt.Printf("ready|%s|%s|%s\n", os.Getenv("ASENTA_PROCESS_VALUE"), os.Getenv("ASENTA_PROCESS_SECRET"), cwd)
		fmt.Fprint(os.Stderr, strings.Repeat("s", 256*1024)+"[stderr-end]\n")
		lines := bufio.NewScanner(os.Stdin)
		lines.Buffer(make([]byte, 4096), 512*1024)
		for lines.Scan() {
			if lines.Text() == "tail" {
				fmt.Print("incomplete-tail")
				return
			}
			fmt.Println(lines.Text())
		}
	case "environment":
		fmt.Println(os.Getenv("ASENTA_PROCESS_SECRET"))
	case "stubborn":
		signal.Ignore(syscall.SIGTERM)
		fmt.Println("stubborn-ready")
		for {
			time.Sleep(time.Hour)
		}
	case "tree", "grandchild":
		directory := os.Getenv("ASENTA_PROCESS_TREE")
		stopping := make(chan os.Signal, 1)
		signal.Notify(stopping, syscall.SIGTERM)
		defer signal.Stop(stopping)
		if mode == "grandchild" {
			_ = os.WriteFile(filepath.Join(directory, "child-ready"), nil, 0600)
			<-stopping
			_ = os.WriteFile(filepath.Join(directory, "child-stopped"), nil, 0600)
			return
		}
		helper, _ := os.Executable()
		child := exec.Command(helper, "-test.run=^TestNativeProcess$", "--", "grandchild")
		if err := child.Start(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		_ = os.WriteFile(filepath.Join(directory, "pids"), []byte(fmt.Sprintf("%d %d", os.Getpid(), child.Process.Pid)), 0600)
		for until := time.Now().Add(3 * time.Second); ; {
			if _, err := os.Stat(filepath.Join(directory, "child-ready")); err == nil {
				break
			}
			if time.Now().After(until) {
				_ = child.Process.Kill()
				_ = child.Wait()
				os.Exit(3)
			}
			time.Sleep(time.Millisecond)
		}
		fmt.Println("tree-ready")
		<-stopping
		_ = child.Wait()
		_ = os.WriteFile(filepath.Join(directory, "leader-stopped"), nil, 0600)
	default:
		os.Exit(4)
	}
}
