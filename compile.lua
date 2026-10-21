-- Compile independent modules with this host's exact Lua ABI. Keep source
-- names and line information for diagnostics; require still loads lazily.
local output = assert(arg[1], "output directory is required")
for index = 2, #arg do
    local path = arg[index]
    local name = assert(path:match("([^/]+)%.lua$"), "expected a Lua source file")
    local input = assert(io.open(path, "rb"))
    local source = assert(input:read("*a"))
    assert(input:close())
    local chunk = assert(load(source, "@" .. name .. ".lua", "t"))
    local file = assert(io.open(output .. "/" .. name .. ".lua", "wb"))
    assert(file:write(string.dump(chunk)))
    assert(file:close())
end
