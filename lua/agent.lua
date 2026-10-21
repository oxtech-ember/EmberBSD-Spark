local json = require("json")
local Client = require("client")
local M = {}

function M.run(config, taskId, role, tools)
    local client = Client.new(config)
    local actor = client:request("GET", "/api/v1/me").user.userId
    local task = client:lease(taskId)
    assert(task.assigneeId == actor, "task belongs to another executor")
    local input = json.array({{role="system", content=role}})
    for _, event in ipairs(client:history()) do
        if event.kind == "message" and event.level ~= "trace" and event.body and event.body ~= "" then
            input[#input + 1] = {role=event.actorId == actor and "assistant" or "user", content=event.body}
        end
    end
    assert(#input > 1, "task has no message")
    local definitions, named = json.array(), {}
    for _, tool in ipairs(tools) do
        assert(not named[tool.name], "duplicate tool name: " .. tool.name)
        named[tool.name] = tool
        definitions[#definitions + 1] = {type="function", name=tool.name,
            description=tool.description, parameters=tool.parameters}
    end
    local calls = 0
    local model = task.seat and task.seat ~= "" and task.seat or config.model.alias
    for turn = 1, (config.limits or {}).maxTurns or 8 do
        if turn > 1 then client:lease(taskId) end
        local response = client:request("POST", "/v1/responses", {model=model,
            input=input, tools=#definitions > 0 and definitions or nil, store=false}, true)
        assert(response.status == "completed", "model response is not complete: " .. tostring(response.status))
        local pending, text = {}, {}
        for _, item in ipairs(response.output) do
            assert(item.status ~= "incomplete", "incomplete model item")
            if item.type == "function_call" then
                assert(type(item.call_id) == "string" and type(item.name) == "string", "invalid function call")
                pending[#pending + 1] = {item=item, args=json.decode(item.arguments)}
            elseif item.type == "message" then
                for _, part in ipairs(item.content or {}) do
                    assert(part.type ~= "refusal", "model refused the request")
                    if part.type == "output_text" then text[#text + 1] = part.text end
                end
            end
            input[#input + 1] = item
        end
        client:append({kind="message", title=#pending > 0 and "tool_choice" or "thinking", level="trace", body=table.concat(text, "\n"),
            modelAlias=model, units=(response.usage or {}).total_tokens or 0})
        if #pending == 0 then
            local answer = table.concat(text, "\n")
            assert(answer ~= "", "model returned no answer or tool call")
            client:append({kind="result", title="result", body=answer, state="completed"})
            return {answer=answer, turns=turn, calls=calls}
        end
        for _, call in ipairs(pending) do
            local tool = named[call.item.name]
            local ok, value = pcall(function()
                assert(tool, "unknown tool: " .. call.item.name)
                local result = tool.invoke(call.args)
                return type(result) == "string" and result or json.encode(result)
            end)
            local output = ok and value or json.encode({error=tostring(value)})
            calls = calls + 1
            client:append({kind="message", title=call.item.name, level="trace", body=output})
            input[#input + 1] = {type="function_call_output", call_id=call.item.call_id, output=output}
        end
    end
    error("maxTurns reached without a result")
end
return M
