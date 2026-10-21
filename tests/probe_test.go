package probe

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAgentHTTPS(t *testing.T) {
	for _, scenario := range []string{"answer", "tool", "tool-error", "tool-encoding-error", "read-disconnect", "untrusted", "cut"} {
		t.Run(scenario, func(t *testing.T) {
			f := newFixture(t, scenario)
			binary, _ := filepath.Abs("../build/agent-lua")
			entry, _ := filepath.Abs("../lua/main.lua")
			cmd := exec.Command(binary, entry, f.config, "task")
			cmd.Env = append(os.Environ(), "PROBE_TOKEN=server-test-key", "PROBE_MODEL_KEY=model-test-key")
			started := time.Now()
			output, peak, err := runObserved(cmd)
			f.mu.Lock()
			defer f.mu.Unlock()
			if scenario == "untrusted" || scenario == "cut" {
				if err == nil || f.completed {
					t.Fatalf("invalid input completed a task: %s", output)
				}
				if f.calls != 0 {
					t.Fatal("an incomplete model response executed a tool")
				}
				return
			}
			if err != nil {
				t.Fatalf("agent failed: %v\n%s", err, output)
			}
			if !f.completed || f.result != "Ready." {
				t.Fatalf("result was not delivered: %s", output)
			}
			wantTurns := 1
			if strings.HasPrefix(scenario, "tool") {
				wantTurns = 2
			}
			if f.turns != wantTurns {
				t.Fatalf("model turns: %d, want %d", f.turns, wantTurns)
			}
			if scenario == "tool" && f.calls != 1 {
				t.Fatal("tool call was not traced")
			}
			if scenario == "read-disconnect" && !f.disconnected {
				t.Fatal("disconnect was not exercised")
			}
			var report map[string]any
			if err := json.Unmarshal(output, &report); err != nil {
				t.Fatalf("invalid result report: %s", output)
			}
			if report["answer"] != "Ready." {
				t.Fatalf("answer missing: %s", output)
			}
			t.Logf("elapsed=%s observed_peak_rss_bytes=%d report=%s", time.Since(started), peak, output)
		})
	}
}
