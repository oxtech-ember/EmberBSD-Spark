-- Exercise the C host without a server, model, or private configuration.
local core = require("asenta.core")
local stats = core.stats()
print("EmberBSD-Spark host API " .. core.apiVersion)
print("Lua memory bytes: " .. stats.luaBytes)
