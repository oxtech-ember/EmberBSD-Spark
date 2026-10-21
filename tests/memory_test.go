package probe

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Observe the executable after exec: rusage may include the test driver's fork.
func runObserved(cmd *exec.Cmd) ([]byte, int64, error) {
	output := &strings.Builder{}
	cmd.Stdout, cmd.Stderr = output, output
	if err := cmd.Start(); err != nil {
		return nil, 0, err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	interval := time.Millisecond
	if runtime.GOOS == "netbsd" {
		interval = 10 * time.Millisecond
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	var peak int64
	for {
		select {
		case err := <-done:
			return []byte(output.String()), peak, err
		case <-ticker.C:
			peak = max(peak, residentBytes(cmd.Process.Pid))
		}
	}
}

func residentBytes(pid int) int64 {
	if runtime.GOOS == "netbsd" {
		// NetBSD procfs has no Linux VmHWM. ps reports current RSS in KiB.
		output, err := exec.Command("/bin/ps", "-p", strconv.Itoa(pid), "-o", "rss=").Output()
		if err == nil {
			kb, _ := strconv.ParseInt(strings.TrimSpace(string(output)), 10, 64)
			return kb * 1024
		}
		return 0
	}
	status, _ := os.ReadFile(fmt.Sprintf("/proc/%d/status", pid))
	for _, line := range strings.Split(string(status), "\n") {
		var kb int64
		if _, err := fmt.Sscanf(line, "VmHWM: %d kB", &kb); err == nil {
			return kb * 1024
		}
	}
	return 0
}
