//go:build darwin || linux || netbsd

package probe

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func serviceTestBinary() string {
	if binary := os.Getenv("OXTORG_TEST_AGENT_BINARY"); binary != "" {
		return binary
	}
	return "../build/agent-lua"
}

func TestDirectServiceOwnsItsPIDAndReleasesIt(t *testing.T) {
	for _, scenario := range []string{"stop", "crash", "replacement"} {
		t.Run(scenario, func(t *testing.T) {
			directory := t.TempDir()
			pidfile := filepath.Join(directory, "agent.pid")
			script := filepath.Join(directory, "service.lua")
			if err := os.WriteFile(script, []byte(`print("ready"); io.stdout:flush(); while true do require("asenta.core").sleep(1000) end`), 0600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			command := func() *exec.Cmd {
				cmd := exec.CommandContext(ctx, serviceTestBinary(), script)
				cmd.Env = append(os.Environ(), "OXTORG_AGENT_PIDFILE="+pidfile, "OXTORG_AGENT_SYSLOG=0")
				return cmd
			}
			cmd := command()
			stdout, err := cmd.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			defer cmd.Process.Kill()
			if line, err := bufio.NewReader(stdout).ReadString('\n'); err != nil || line != "ready\n" {
				t.Fatalf("startup: %q %v", line, err)
			}
			pid := fmt.Sprintf("%d\n", cmd.Process.Pid)
			if body, err := os.ReadFile(pidfile); err != nil || string(body) != pid {
				t.Fatalf("PID does not name the application: %q %v", body, err)
			}
			if output, err := command().CombinedOutput(); err == nil || !strings.Contains(string(output), "Cannot initialize agent service") {
				t.Fatalf("duplicate accepted: %s %v", output, err)
			}
			if body, _ := os.ReadFile(pidfile); string(body) != pid {
				t.Fatalf("duplicate changed PID file: %s", body)
			}
			if scenario == "replacement" {
				if err := os.Rename(pidfile, pidfile+".old"); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(pidfile, []byte("another owner\n"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			signal := syscall.SIGTERM
			if scenario == "crash" {
				signal = syscall.SIGKILL
			}
			if err := cmd.Process.Signal(signal); err != nil {
				t.Fatal(err)
			}
			if err := cmd.Wait(); err == nil {
				t.Fatal("signaled process returned success")
			}
			body, err := os.ReadFile(pidfile)
			switch scenario {
			case "stop":
				if !os.IsNotExist(err) {
					t.Fatalf("PID remains after SIGTERM: %q %v", body, err)
				}
			case "replacement":
				if err != nil || string(body) != "another owner\n" {
					t.Fatalf("removed replacement: %q %v", body, err)
				}
			case "crash":
				if err != nil || string(body) != pid {
					t.Fatalf("crash fixture lost stale PID: %q %v", body, err)
				}
				if err := os.WriteFile(script, []byte(`require("asenta.core").log("restarted explicitly")`), 0600); err != nil {
					t.Fatal(err)
				}
				if output, err := command().CombinedOutput(); err != nil || string(output) != "restarted explicitly\n" {
					t.Fatalf("stale PID prevents explicit restart: %s %v", output, err)
				}
				if _, err := os.Stat(pidfile); !os.IsNotExist(err) {
					t.Fatalf("PID remains after normal exit: %v", err)
				}
			}
		})
	}
}

func TestDirectServiceReportsFailureAndRejectsLinkedPID(t *testing.T) {
	directory := t.TempDir()
	pidfile, script := filepath.Join(directory, "agent.pid"), filepath.Join(directory, "broken.lua")
	if err := os.WriteFile(script, []byte(`error("service fixture failed")`), 0600); err != nil {
		t.Fatal(err)
	}
	command := func() *exec.Cmd {
		cmd := exec.Command(serviceTestBinary(), script)
		cmd.Env = append(os.Environ(), "OXTORG_AGENT_PIDFILE="+pidfile, "OXTORG_AGENT_SYSLOG=0")
		return cmd
	}
	if output, err := command().CombinedOutput(); err == nil || !strings.Contains(string(output), "service fixture failed") {
		t.Fatalf("failure is not observable: %s %v", output, err)
	}
	if _, err := os.Stat(pidfile); !os.IsNotExist(err) {
		t.Fatalf("PID remains after error: %v", err)
	}
	target := filepath.Join(directory, "unrelated")
	if err := os.WriteFile(target, []byte("preserved"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, pidfile); err != nil {
		t.Fatal(err)
	}
	if output, err := command().CombinedOutput(); err == nil || !strings.Contains(string(output), "Cannot initialize agent service") {
		t.Fatalf("linked PID accepted: %s %v", output, err)
	}
	if body, _ := os.ReadFile(target); string(body) != "preserved" {
		t.Fatal("linked target changed")
	}
}
