package probe

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// Each page fits the HTTP limit; the combined history must fit it as well.
func TestHistoryLimit(t *testing.T) {
	for _, pages := range []int{2, 4} {
		name := "long-history"
		if pages == 4 {
			name = "history-over-limit"
		}
		t.Run(name, func(t *testing.T) {
			f := newFixture(t, "history")
			f.historyPages = pages
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, "../build/agent-lua", "../lua/main.lua", f.config, "task")
			cmd.Env = append(os.Environ(), "PROBE_TOKEN=server-test-key", "PROBE_MODEL_KEY=model-test-key")
			started := time.Now()
			output, peak, err := runObserved(cmd)
			f.mu.Lock()
			defer f.mu.Unlock()
			if f.historyReads != pages {
				t.Fatalf("read %d history pages, want %d: %s", f.historyReads, pages, output)
			}
			if pages == 4 {
				if err == nil || !strings.Contains(string(output), "history exceeds maxBytes") || f.turns != 0 || len(f.requests) != 0 {
					t.Fatalf("oversized history was not rejected before model/events: %v\n%s", err, output)
				}
				return
			}
			if err != nil || !f.completed || f.result != "Ready." || f.turns != 1 {
				t.Fatalf("long history failed: %v\n%s", err, output)
			}
			t.Logf("history_body_bytes=%d elapsed=%s observed_peak_rss_bytes=%d report=%s", pages*len(historyBody(1)), time.Since(started), peak, output)
		})
	}
}
