-- Preserve installation settings while replacing only known local tools.
package.path=arg[1] .. "/?.lua;" .. package.path
local json,fs=require("json"),require("asenta.fs")
local path=assert(arg[2],"configuration path is required")
local directory,name=path:match("^(.*)/([^/]+)$")
local root=assert(fs.root(assert(directory),false))
local config=json.decode(assert(root:read(name,1024*1024)))
for _,spec in ipairs(config.mcp or {}) do
    if (spec.alias=="equipment" or spec.alias=="bluetooth") and spec.command and
        spec.command:match("([^/]+)$")=="oxtorg-mcp-" .. spec.alias then
        spec.command=nil;spec.module=spec.alias
    end
end
assert(root:write(name .. ".native",json.encode(config) .. "\n"))
root:close()
