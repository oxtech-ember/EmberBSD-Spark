package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestGrokUsageCostAndReasoning(t *testing.T) {
	directory := t.TempDir()
	script := `
package.path = arg[1] .. "/?.lua;" .. package.path
local json, Model = require("json"), require("model")

local function check(condition, text)
    if not condition then error(text, 0) end
end

local catalogue = {object="list", data={
    {id="grok-imagine-image", object="model", owned_by="xai", context_length=1024,
        image_price=200000000, pricing={{quality="medium", resolution="1k", price_per_image=200000000}}},
    {id="grok-4.7", object="model", owned_by="xai", context_length=500000,
        prompt_text_token_price=20000, cached_prompt_text_token_price=5000,
        completion_text_token_price=60000, prompt_text_token_price_long_context=40000,
        cached_prompt_text_token_price_long_context=10000,
        completion_text_token_price_long_context=120000, long_context_threshold=200000},
    {id="grok-bare", object="model", owned_by="xai", context_length=500000}
}}

local function completed(usage)
    return {status="completed", output={
        {type="reasoning", status="completed", encrypted_content="cipher-not-answer",
            summary={{type="summary_text", text="Hidden reasoning trace"}}},
        {type="message", status="completed", content={{type="output_text", text="Visible answer."}}}
    }, usage=usage}
end

local function run(alias, body)
    local posts = {}
    local client = {}
    function client:request(method, path, request, model)
        check(model, "model endpoint was not selected")
        if method == "GET" then
            check(path == "/v1/models", "catalogue path")
            return catalogue, 200
        end
        posts[#posts + 1] = request
        check(path == "/v1/responses" and request.store == false, "responses request")
        check(request.model == alias, "request model")
        check(request.safety_identifier == nil, "safety_identifier is off by default")
        return body, 200
    end
    local model = Model.new({model={alias=alias, fallback="grok-4.6"}}, client)
    local reply = model:request(json.array({{role="user", content="Read"}}), json.array(), {seat=alias})
    return reply, posts, model.seat
end

local ticks, posts, seat = run("grok-4.7", completed({
    input_tokens=1000, output_tokens=10, total_tokens=1010,
    input_tokens_details={cached_tokens=200}, cost_in_usd_ticks=37756000,
    cost_in_nano_usd=1}))
check(ticks.answer == "Visible answer.", "reasoning text became the answer: " .. ticks.answer)
check(not ticks.answer:find("Hidden", 1, true) and not ticks.answer:find("cipher", 1, true),
    "reasoning item was not ignored")
check(ticks.usage.costMicro == 3775, "cost ticks were not used: " .. tostring(ticks.usage.costMicro))
check(ticks.priceKnown and not ticks.usage.spendUnknown, "provider cost was treated as unknown")
check(ticks.usage.units == 1010 and ticks.usage.cachedUnits == 200, "token counts changed")
check(#posts == 1, "paid response was replayed")
check(seat.contextWindow == 500000, "context_length was dropped")

local nano = run("grok-4.7", completed({
    input_tokens=1000, output_tokens=10, total_tokens=1010, cost_in_nano_usd=3800000}))
check(nano.usage.costMicro == 3800, "nano-USD cost was not used: " .. tostring(nano.usage.costMicro))
check(nano.priceKnown and not nano.usage.spendUnknown, "nano-USD cost was unknown")

local zero = run("grok-4.7", completed({
    input_tokens=1000, output_tokens=10, total_tokens=1010,
    input_tokens_details={cached_tokens=200}, cost_in_usd_ticks=0}))
check(zero.usage.costMicro == 0 and zero.priceKnown and not zero.usage.spendUnknown,
    "a reported zero cost fell back to the catalogue")

local priced = run("grok-4.7", completed({
    input_tokens=1000, output_tokens=10, total_tokens=1010,
    input_tokens_details={cached_tokens=200}}))
check(priced.usage.costMicro == 1760, "short-context catalogue cost: " .. tostring(priced.usage.costMicro))
check(priced.priceKnown and not priced.usage.spendUnknown, "xAI catalogue price was unknown")

local long = run("grok-4.7", completed({
    input_tokens=250000, output_tokens=10, total_tokens=250010}))
check(long.usage.costMicro == 1000120, "long-context catalogue cost: " .. tostring(long.usage.costMicro))

local invalid = run("grok-4.7", completed({
    input_tokens=1000, output_tokens=10, total_tokens=1010,
    input_tokens_details={cached_tokens=200}, cost_in_usd_ticks=-1}))
check(invalid.usage.costMicro == 1760, "invalid ticks replaced the catalogue cost")

local bare = run("grok-bare", completed({
    input_tokens=40, output_tokens=2, total_tokens=42}))
check(bare.answer == "Visible answer.", "a catalogue without prices failed")
check(bare.usage.costMicro == 0 and not bare.priceKnown and not bare.usage.spendUnknown,
    "missing prices were treated as a free or failed request")
local noted = false
for _, note in ipairs(bare.accountingNotes) do
    if note == "Catalogue pricing is unknown; costMicro is not a free price." then noted = true end
end
check(noted, "missing prices did not keep the unknown-price note")
`
	file := filepath.Join(directory, "grok.lua")
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
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, binary, file, modules)
	command.Env = append(os.Environ(), "LUA_PATH=/usr/local/share/lua/5.5/?.lua;;")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("xAI cost fixture failed: %v\n%s", err, output)
	}
}

func TestGrokRefusalSelectsFallback(t *testing.T) {
	directory := t.TempDir()
	script := `
package.path = arg[1] .. "/?.lua;" .. package.path
local json, Model = require("json"), require("model")

local function check(condition, text)
    if not condition then error(text, 0) end
end

local catalogue = {object="list", data={
    {id="grok-4.7", object="model", owned_by="xai", context_length=500000},
    {id="grok-4.6", object="model", owned_by="xai", context_length=500000},
    {id="oxtech_lite", metadata={display_name="Luna", context_window=400000,
        pricing={currency="USD", input_per_mtok=1, output_per_mtok=6}}}
}}

local function refusal(usage)
    return {status="completed", output={
        {type="reasoning", status="completed", encrypted_content="cipher-not-answer",
            summary={{type="summary_text", text="Hidden reasoning trace"}}},
        {type="message", status="completed", content={
            {type="refusal", refusal="The model cannot generate a response."}}}
    }, usage=usage or {input_tokens=20, output_tokens=1, total_tokens=21}}
end

local function answer(text)
    return {status="completed", output={
        {type="message", status="completed", content={{type="output_text", text=text}}}
    }, usage={input_tokens=8, output_tokens=2, total_tokens=10}}
end

local function run(alias, scripted)
    local posts = {}
    local client = {}
    function client:request(method, path, request, model)
        check(model, "model endpoint was not selected")
        if method == "GET" then return catalogue, 200 end
        posts[#posts + 1] = request.model
        local item = table.remove(scripted[request.model], 1)
        if item.error then error(item.error, 0) end
        return item, 200
    end
    local model = Model.new({model={alias=alias, fallback="grok-4.6"}}, client)
    local ok, reply = pcall(model.request, model, json.array({{role="user", content="Read"}}), json.array(), {seat=alias})
    return ok, reply, posts
end

local notFound = {status=404,
    message="The model grok-old does not exist or your team team_1 does not have access to it.",
    body={code="not-found", error="The model grok-old does not exist or your team team_1 does not have access to it."}}

local ok, reply, posts = run("grok-4.7", {["grok-4.7"]={refusal()}, ["grok-4.6"]={answer("Spare answer.")}})
check(ok and reply.answer == "Spare answer.", "xAI refusal did not select the fallback")
check(not reply.answer:find("Hidden", 1, true) and not reply.answer:find("cipher", 1, true),
    "reasoning text leaked into the fallback answer")
check(#posts == 2 and posts[1] == "grok-4.7" and posts[2] == "grok-4.6", "paid refusal was replayed")

ok, reply, posts = run("oxtech_lite", {oxtech_lite={refusal({input_tokens=20, output_tokens=1, total_tokens=21,
    cost_in_usd_ticks=10000000})}, ["grok-4.6"]={answer("Spare answer.")}})
check(ok and reply.answer == "Spare answer." and #posts == 2 and posts[1] == "oxtech_lite",
    "a refusal that reports cost ticks did not select the fallback")

ok, reply, posts = run("oxtech_lite", {oxtech_lite={refusal()}})
check(not ok and reply.reason == "model_refused" and #posts == 1, "Asenta refusal changed its fallback rule")

ok, reply, posts = run("grok-4.7", {["grok-4.7"]={{error=notFound}}, ["grok-4.6"]={answer("Spare answer.")}})
check(ok and reply.answer == "Spare answer." and #posts == 2 and posts[1] == "grok-4.7" and posts[2] == "grok-4.6",
    "xAI not-found did not select the fallback once")

ok, reply, posts = run("grok-4.7", {["grok-4.7"]={{error={message="transport: connection closed"}}}})
check(not ok and #posts == 1, "a transport failure replayed a model request")

ok, reply, posts = run("grok-4.7", {["grok-4.7"]={{error={status=400,
    message="A field in the POST request body has an invalid format."}}}})
check(not ok and #posts == 1, "an invalid xAI request selected the fallback")

ok, reply, posts = run("grok-4.7", {["grok-4.7"]={{error={status=429,
    message="You are sending requests too frequently and have reached the rate limit."}}}})
check(not ok and #posts == 1, "an xAI rate limit selected the fallback")

ok, reply, posts = run("grok-4.7", {["grok-4.7"]={{error={status=400,
    message="request blocked by safety policy"}}}, ["grok-4.6"]={answer("Spare answer.")}})
check(ok and reply.answer == "Spare answer." and #posts == 2, "Asenta safety-policy fallback changed")

ok, reply, posts = run("grok-4.7", {["grok-4.7"]={refusal()}, ["grok-4.6"]={refusal()}})
check(not ok and reply.reason == "model_refused" and #posts == 2 and posts[1] == "grok-4.7" and posts[2] == "grok-4.6",
    "a refused fallback replayed a paid request")
`
	file := filepath.Join(directory, "grok-refusal.lua")
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
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, binary, file, modules)
	command.Env = append(os.Environ(), "LUA_PATH=/usr/local/share/lua/5.5/?.lua;;")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("xAI refusal fixture failed: %v\n%s", err, output)
	}
}
