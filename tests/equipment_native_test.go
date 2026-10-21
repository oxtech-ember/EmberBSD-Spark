package probe

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// A blocked real HTTP call must not pause native acquisition. The same test
// checks the deployed registry route, bounded history, snapshot restore and
// installation-owned journal policy against captured NetBSD source formats.
func TestNativeEquipmentAcquiresDuringHTTPAndRestores(t *testing.T) {
	dir := t.TempDir()
	proc := filepath.Join(dir, "proc")
	if err := os.Mkdir(proc, 0700); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{
		"loadavg": "0.00 0.00 0.00 1/20 30000\n",
		"uptime":  "1284.62 1190.49\n",
		"meminfo": "        total:    used:    free:  shared: buffers: cached:\nMem:  2051473408 436023296 1615450112        0 274640896 366870528\nMemTotal:   2003392 kB\nMemFree:    1577588 kB\nBuffers:    1577588 kB\nCached:      358272 kB\n",
	} {
		if err := os.WriteFile(filepath.Join(proc, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	thermal := filepath.Join(dir, "sys", "class", "thermal", "thermal_zone0")
	if err := os.MkdirAll(thermal, 0700); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{"temp": "42000\n", "type": "cpu-thermal\n"} {
		if err := os.WriteFile(filepath.Join(thermal, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	journal := "Oct  5 12:00:00 board pump: initial\nOct  5 12:00:00 board pump-extra: forbidden\n" +
		"Oct  5 12:00:01 board pump[12]: high <U+00b0>C <U+41>\n" +
		"Oct  5 12:00:02 board syslogd[1]: last message repeated 3 times\n" +
		"Oct  5 12:00:03 board secret: secret\n"
	if err := os.WriteFile(filepath.Join(dir, "messages"), []byte(journal), 0600); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(450 * time.Millisecond)
		io.WriteString(w, "ready")
	}))
	defer server.Close()
	runEquipmentScenario(t, dir, equipmentScenario, server.URL)
}

func runEquipmentScenario(t *testing.T, dir, source string, extra ...string) {
	t.Helper()
	script := filepath.Join(dir, "equipment-check.lua")
	if err := os.WriteFile(script, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	modules, err := filepath.Abs("../lua")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	args := append([]string{script, modules, dir}, extra...)
	cmd := exec.CommandContext(ctx, "../build/agent-lua", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("native equipment: %v\n%s", err, out)
	}
}

const equipmentScenario = `
package.path=arg[1] .. "/?.lua;" .. package.path
local fs, http, json = require("asenta.fs"), require("asenta.http"), require("json")
local Native, Registry, Sequence = require("native"), require("registry"), require("sequence")
local root=assert(fs.root(arg[2],false))
local spec={alias="equipment",module="equipment",env={EQUIPMENT_UNITS="pump"},
  machine={proc=arg[2].."/proc",sys=arg[2].."/sys",syslog=arg[2].."/messages"},
  args={"-collect-interval","20ms","-collect-history","4","-collect-store","history/native.bin",
    "-collect-temperature","40","-collect-memory-percent","50"}}
local function connect()
  local connection=Native.connect(spec,{root=root,declarationRoot=root})
  assert(connection:report().connected,connection:report().reason)
  local registry=Registry.new{root=root}
  for _,tool in ipairs(connection:tools()) do
    assert(tool.class=="read" and tool.foreign==false and tool.source=="equipment" and #tool.program==64)
    registry:add(tool)
  end
  assert(connection:report().tools==4 and #connection:report().declared==4)
  return connection,registry
end
local connection,registry=connect()
local function invoke(name,args)
  local answer=registry:invoke{name=name,args=args or {}}
  assert(not answer.error,answer.output)
  return answer.raw
end
local state=invoke("equipment_state")
assert(state.load1==0 and state.uptimeSeconds==1284)
assert(state.memoryTotalKb==2003392 and state.memoryAvailableKb==1845792)
assert(#state.temperatures==1 and state.temperatures[1].zone=="cpu-thermal" and state.temperatures[1].celsius==42)
assert(registry:invoke{name="equipment_state",args={arbitrary=true}}.error)
assert(registry:invoke{name="equipment_journal",args={unit="secret"}}.error)
local journal=invoke("equipment_journal",{unit="pump",lines=2})
assert(journal:find("high \u{00b0}C <U+41>",1,true) and journal:find("last message repeated 3 times",1,true))
assert(not journal:find("forbidden",1,true) and not journal:find("initial",1,true) and not journal:find("secret",1,true))
-- Snapshot fsync can exceed three 20 ms sampling intervals. A collection gap
-- is then valid. Check the unchanged sensor threshold separately from latency.
local function checkAlerts()
  local alerts=invoke("equipment_alerts")
  assert(alerts.enabled and alerts.status=="alert")
  assert(alerts.thresholds.temperatureCelsius==40 and alerts.thresholds.memoryUsedPercent==50 and alerts.thresholds.load==0)
  local thresholds,gaps=0,0
  for _,issue in ipairs(alerts.issues) do
    if issue.code=="gap" and issue.source=="collection" then
      gaps=gaps+1
    else
      assert(issue.code=="threshold" and issue.source=="temperature:cpu-thermal",json.encode(alerts))
      thresholds=thresholds+1
    end
  end
  assert(thresholds==1 and gaps<=1,json.encode(alerts))
end
checkAlerts()
local before=invoke("equipment_history",{limit=4})
local status=assert(http.request{url=arg[3],method="GET",timeoutMs=3000,maxBytes=1024})
assert(status==200)
local after=invoke("equipment_history",{limit=2})
assert(after.retained==4 and #after.readings==2 and after.discarded>before.discarded)
assert(Sequence.is(after.readings) and after.persisted and after.coverage=="retained_samples_only")
assert(#after.readings[1].errors==0 and after.readings[1].observedAt<=after.readings[2].observedAt)
checkAlerts()
local discarded=after.discarded
connection:close()
assert(not connection:report().connected)
assert(registry:invoke{name="equipment_state"}.error)
connection,registry=connect()
local restored=invoke("equipment_history",{limit=4})
assert(restored.persisted and restored.retained==4 and restored.discarded>discarded)
connection:close()
-- A private corrupt snapshot is never replaced by an empty history.
assert(root:write("history/native.bin","corrupt snapshot"))
connection,registry=connect()
assert(invoke("equipment_alerts").status=="degraded")
assert(invoke("equipment_history").storeError)
connection:close()
assert(root:read("history/native.bin")=="corrupt snapshot")
-- Collection errors retain partial measurements and never claim zero pressure.
spec.args={"-collect-interval","1s","-collect-temperature","40"}
assert(root:write("proc/meminfo","MemTotal: 1234 kB\n"))
connection,registry=connect()
local partial=invoke("equipment_history").readings[1]
assert(partial.reading.uptimeSeconds==1284 and partial.errors[1].source=="memory")
connection:close()
-- Explicit empty journal policy is accepted; omission is rejected.
spec.args={};spec.env.EQUIPMENT_UNITS=""
connection,registry=connect()
assert(invoke("equipment_history").status=="disabled")
assert(invoke("equipment_alerts").status=="disabled")
assert(registry:invoke{name="equipment_journal",args={unit="pump"}}.error)
connection:close()
spec.env={}
assert(not Native.connect(spec,{root=root}):report().connected)
-- Snapshots cannot walk outside the installation's state root.
spec.env={EQUIPMENT_UNITS="pump"};spec.args={"-collect-interval","1s","-collect-store","../escape"}
connection,registry=connect()
assert(invoke("equipment_alerts").status=="degraded")
assert(invoke("equipment_history").retained==0)
connection:close();root:close()
`
