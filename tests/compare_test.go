package probe

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// Compare real executables on the same answer, without rewriting a Go loop.
func TestCompareAnswers(t *testing.T) {
	goAgent := os.Getenv("GO_AGENT")
	if goAgent == "" {
		t.Skip("set GO_AGENT to compare the existing static Go agent")
	}
	for _, runtime := range []string{"c-lua", "go"} {
		t.Run(runtime, func(t *testing.T) {
			f := newFixture(t, "answer")
			raw, err := os.ReadFile(f.config)
			if err != nil {
				t.Fatal(err)
			}
			var cfg map[string]any
			if err := json.Unmarshal(raw, &cfg); err != nil {
				t.Fatal(err)
			}
			dir := filepath.Dir(f.config)
			ca := cfg["transport"].(map[string]any)["caFile"].(string)
			binary, _ := filepath.Abs("../build/agent-lua")
			entry, _ := filepath.Abs("../lua/run.lua")
			args := []string{entry, f.config, "task", filepath.Join(dir, "state")}
			if runtime == "go" {
				binary, args = goAgent, []string{"-config", f.config, "-once"}
				delete(cfg, "transport")
				delete(cfg, "luaTools")
				cfg["limits"].(map[string]any)["workRoot"] = filepath.Join(dir, "work")
				raw, err = json.Marshal(cfg)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(f.config, raw, 0600); err != nil {
					t.Fatal(err)
				}
			}
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, binary, args...)
			cmd.Env = append(os.Environ(), "PROBE_TOKEN=server-test-key", "PROBE_MODEL_KEY=model-test-key", "SSL_CERT_FILE="+ca,
				"OXTORG_WORKTREE="+filepath.Join(dir, "worktree"), "OXTORG_WORKS="+filepath.Join(dir, "works"),
				"OXTORG_WORKSHOP="+filepath.Join(dir, "workshop"), "OXTORG_NOTEBOOK=")
			start := time.Now()
			output, peak, err := runObserved(cmd)
			elapsed := time.Since(start)
			if err != nil {
				t.Fatalf("%s failed: %v\n%s", runtime, err, output)
			}
			f.mu.Lock()
			defer f.mu.Unlock()
			if !f.completed || f.result != "Ready." || f.turns != 1 {
				t.Fatalf("incomplete baseline: completed=%t result=%q turns=%d version=%d\n%s", f.completed, f.result, f.turns, f.version, output)
			}
			info, err := os.Stat(binary)
			if err != nil {
				t.Fatal(err)
			}
			t.Logf("runtime=%s executable_bytes=%d observed_peak_rss_bytes=%d elapsed=%s events=%d", runtime, info.Size(), peak, elapsed, len(f.requests))
		})
	}
}
