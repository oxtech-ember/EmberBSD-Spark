package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestRegistryKeepsIdentityAndFailedToolAnswers(t *testing.T) {
	script := `
package.path = arg[1] .. "/?.lua;" .. package.path
local json, Registry = require("json"), require("registry")
local registry, calls = Registry.new({toolOutput=4096}), 0
local raw = json.decode([[{"content":[{"type":"text","text":"A short summary"},
  {"type":"resource","resource":{"uri":"memory://reading","text":"Measured 7"}},
  {"type":"image","mimeType":"image/png","data":"aW1hZ2U="}],
  "structuredContent":{"reading":7},"isError":false}]])
local registered = registry:add{name="sensor/read", class="read", foreign=true,
    source="sensor", program="sha256:fixture", parameters={type="object"},
    invoke=function(args)
        calls = calls + 1
        if args.fail then error({message="sensor unavailable"}, 0) end
        return raw
    end}
assert(registry:find("sensor_read") == registered and not registry:find("sensor/read"))
assert(registered.class == "read" and registered.program == "sha256:fixture" and registered.source == "sensor")
local ok, why = pcall(registry.add, registry, {name="sensor.read", class="read", invoke=function() error("wrong tool") end})
assert(not ok and tostring(why):find("collide", 1, true))
local definitions = registry:definitions()
assert(#definitions == 1 and definitions[1].name == "sensor_read" and definitions[1].type == "function")

local answer = registry:invoke{name="sensor_read", args={}}
assert(not answer.error and answer.foreign and answer.tool == registered and answer.raw == raw)
assert(json.decode(answer.output).reading == 7, "model must read the structure, not its summary")
assert(answer.raw.content[3].data == "aW1hZ2U=", "binary content was lost")
answer = registry:invoke{name="sensor_read", args={fail=true}}
assert(answer.error and answer.output:find("sensor unavailable", 1, true) and answer.foreign)
answer = registry:invoke{name="sensor_read", args={}, error="Invalid function arguments"}
assert(answer.error and calls == 2, "invalid model arguments executed the tool")
answer = registry:invoke{name="unknown", args={}}
assert(answer.error and calls == 2, "unknown tool ended the workflow")

-- A later successful call still works, and cutting model text does not cut raw.
raw.structuredContent = nil
answer = registry:invoke{name="sensor_read", args={}}
assert(not answer.error and answer.output:find("Measured 7", 1, true) and answer.output:find("not read", 1, true))
raw.structuredContent = {large=string.rep("x", 12000), reading=7}
answer = registry:invoke{name="sensor_read", args={}}
assert(not answer.error and #answer.output < 4396 and answer.output:find("was cut", 1, true))
assert(answer.output:find('"reading":7', 1, true) and #answer.raw.structuredContent.large == 12000)
`
	file := filepath.Join(t.TempDir(), "registry.lua")
	if err := os.WriteFile(file, []byte(script), 0600); err != nil {
		t.Fatal(err)
	}
	binary, err := filepath.Abs("../build/agent-lua")
	if err != nil {
		t.Fatal(err)
	}
	modules, err := filepath.Abs("../lua")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if output, err := exec.CommandContext(ctx, binary, file, modules).CombinedOutput(); err != nil {
		t.Fatalf("tool registry contract failed: %v\n%s", err, output)
	}
}
