assert(_VERSION == "Lua 5.5")
collectgarbage("collect")
local before = host.stats().luaBytes
for pass = 1, 20 do
    local values = {}
    for n = 1, 10000 do values[n] = {n, string.rep(tostring(n), 8)} end
    assert(#values == 10000)
    values = nil
    collectgarbage("collect")
end
local after = host.stats()
assert(after.luaPeakBytes > before + 100000)
assert(after.luaBytes < before + 100000)
print("Lua 5.5 state, allocator, GC and shutdown passed")
