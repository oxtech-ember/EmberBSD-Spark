local directory = arg[0]:match("^(.*[/])") or "./"
package.path = directory .. "?.lua;" .. package.path
local json = require("json")
local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = assert(file:read("*a"))
    file:close()
    return text
end
assert(arg[1] and arg[2], "Usage: agent-lua main.lua config.json task-id")
local config = json.decode(read(arg[1]))
local base = arg[1]:match("^(.*[/])") or "./"
local function path(name) return name:sub(1,1) == "/" and name or base .. name end
local role = read(path(assert(config.roleFile, "roleFile is required")))
local tools = config.luaTools or {}
for _, tool in ipairs(tools) do
    tool.invoke = assert(loadfile(path(tool.file), "t"))()
    assert(type(tool.invoke) == "function", "tool must return function(args)")
end
if config.transport and config.transport.caFile and config.transport.caFile ~= "" then
    config.transport.caFile = path(config.transport.caFile)
end
local result = require("agent").run(config, arg[2], role, tools)
result.resources = require("asenta.core").stats()
io.write(json.encode(result), "\n")
