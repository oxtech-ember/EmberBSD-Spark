package probe

import (
	"bufio"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestTerminationDuringNativeRead(t *testing.T) {
	file := filepath.Join(t.TempDir(), "read.lua")
	if err := os.WriteFile(file, []byte(`io.stdout:write("ready\n"); io.stdout:flush(); io.read("*a"); io.write("continued")`), 0600); err != nil {
		t.Fatal(err)
	}
	binary, _ := filepath.Abs("../build/agent-lua")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, file)
	input, _ := cmd.StdinPipe()
	defer input.Close()
	output, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	line, err := bufio.NewReader(output).ReadString('\n')
	if err != nil || line != "ready\n" {
		t.Fatalf("reader never became ready: %q %v", line, err)
	}
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	err = cmd.Wait()
	if err == nil || ctx.Err() != nil {
		t.Fatalf("SIGTERM did not stop the native read: %v", err)
	}
}
