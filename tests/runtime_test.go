package probe

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// Kill the host inside an effect. Recovery uses the state written BEFORE the
// side effect, across actual Lua processes rather than an in-memory checkpoint.
func TestRuntimeRestartsDeliveryButNotAction(t *testing.T) {
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(directory, "runtime.lua")
	source := `package.path = arg[1] .. "/?.lua;" .. package.path
local fs, Runtime, json = require("asenta.fs"), require("runtime"), require("json")
local root = assert(fs.root(arg[2], false))
local kind, mode = arg[3], arg[4]
local delivered = 0
local handlers = {}
handlers[kind] = function(input, effect)
    local stored = json.decode(assert(root:read(kind .. ".json")))
    assert(stored.mode == "waiting" and stored.pending.id == effect.id)
    assert(stored.pending.input.requestId == input.requestId)
    if not root:stat("remote-" .. kind) then
        assert(root:write("remote-" .. kind, input.requestId))
        delivered = delivered + 1
    else
        assert(root:read("remote-" .. kind) == input.requestId)
    end
    if mode == "crash" then os.exit(73) end
    return {accepted=input.requestId}
end
local attempt = Runtime.open(root, kind,
    {taskId="task", attemptId="attempt-" .. kind, data={revision="pinned"}}, handlers)
if mode == "crash" then
    attempt:issue({kind=kind, input={requestId="same-key"}, next="next"})
    error("the fixture did not crash")
else
    local state = attempt:resume()
    assert(state.data.revision == "pinned" and delivered == 0)
    if kind == "append" then
        assert(state.mode == "active" and state.phase == "next")
        assert(state.last.value.accepted == "same-key")
    else
        assert(state.mode == "parked" and state.outcome == "unknown_tool_outcome")
        assert(state.pending.id == "attempt-tool/1")
    end
end
attempt:close()
root:close()
`
	if err := os.WriteFile(script, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	binary, _ := filepath.Abs("../build/agent-lua")
	modules, _ := filepath.Abs("../lua")
	for _, kind := range []string{"append", "tool"} {
		cmd := exec.Command(binary, script, modules, directory, kind, "crash")
		output, err := cmd.CombinedOutput()
		if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 73 {
			t.Fatalf("%s did not crash inside its effect: %v %s", kind, err, output)
		}
		cmd = exec.Command(binary, script, modules, directory, kind, "recover")
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%s recovery: %v %s", kind, err, output)
		}
	}
}
