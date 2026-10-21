package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestModelKeepsPaidUsageAndCompleteCalls(t *testing.T) {
	fixtures, err := filepath.Abs("testdata/catalogues.json")
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	script := `
package.path = arg[1] .. "/?.lua;" .. package.path
local json, Model = require("json"), require("model")
local file = assert(io.open(arg[2], "rb"))
local catalogues = json.decode(assert(file:read("*a")))
file:close()
local complete = json.decode([[{"status":"completed","output":[
  {"type":"reasoning","content":[{"text":"Not the answer"}]},
  {"type":"message","content":[{"type":"output_text","text":"Checking."}]},
  {"type":"function_call","call_id":"call-7","name":"read_sensor","arguments":"{\"channel\":3}"}],
  "usage":{"input_tokens":300000,"output_tokens":1000,"total_tokens":301000,
    "input_tokens_details":{"cached_tokens":200000}}}]])
for _, catalogue in ipairs(catalogues) do
    local client, posts = {}, 0
    local failure
    function client:request(method, path, request, model)
        assert(model, "model endpoint was not selected")
        if method == "GET" then return catalogue, 200 end
        posts = posts + 1
        assert(path == "/v1/responses" and request.model == "oxtech_lite")
        assert(request.store == false and request.max_output_tokens == 4096)
        assert(request.tools[1].type == "function" and request.tools[1].name == "read_sensor")
        if failure then error(failure, 0) end
        return complete, 200
    end
    local model = Model.new({model={alias="default", fallback="spare", maxAnswer=4096}}, client)
    local definitions = {{name="read_sensor", parameters={type="object"}}}
    local reply = model:request(json.array({{role="user", content="Read the sensor"}}), definitions, {seat="oxtech_lite"})
    assert(reply.answer == "Checking." and reply.modelAlias == "oxtech_lite" and reply.model == "Luna")
    assert(#reply.calls == 1 and reply.calls[1].id == "call-7" and reply.calls[1].args.channel == 3)
    assert(reply.usage.units == 301000 and reply.usage.cachedUnits == 200000)
    assert(reply.usage.chargedUnits == 121000 and reply.usage.costMicro == 126000)
    assert(not reply.usage.spendUnknown and reply.priceKnown)

    local missing = json.decode([[{"status":"completed","output":[{"type":"message",
      "content":[{"type":"output_text","text":"Ready."}]}]}]])
    local uncounted = Model.parse(missing, model.seat)
    assert(uncounted.usage.spendUnknown and uncounted.usage.units == 0)
    local cut = json.decode(json.encode(complete))
    cut.output[3].status = "incomplete"
    local ok, err = pcall(Model.parse, cut, model.seat)
    assert(not ok and err.reason == "model_incomplete" and not err.calls)
    assert(err.usage.units == 301000 and err.usage.costMicro == 126000, "paid incomplete response lost its usage")

    -- A revoked device and a lost connection are not refusals of this alias.
    for _, rejected in ipairs({{status=401, reason="needs_pairing", message="device revoked"},
        {message="connection closed"}}) do
        failure = rejected
        local before = posts
        ok, err = pcall(model.request, model, {}, definitions, {seat="oxtech_lite"})
        assert(not ok and posts == before + 1 and model.seat.alias == "oxtech_lite")
    end
end
`
	file := filepath.Join(directory, "model.lua")
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
	if output, err := exec.CommandContext(ctx, binary, file, modules, fixtures).CombinedOutput(); err != nil {
		t.Fatalf("Responses/accounting contract failed: %v\n%s", err, output)
	}
}
