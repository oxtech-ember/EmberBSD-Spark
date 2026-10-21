local directory=arg[0]:match("^(.*)/[^/]+$") or "."
package.path=directory .. "/?.lua;" .. package.path
local json=require("json")
assert(arg[1] and arg[2],"Usage: agent-lua run.lua config.json task-id [state-root] [program-dir]")
local file=assert(io.open(arg[1],"rb"))
local config=json.decode(assert(file:read("*a")));file:close()
local base=arg[1]:match("^(.*)/[^/]+$") or "."
if config.transport and config.transport.caFile and config.transport.caFile:sub(1,1)~="/" then
    config.transport.caFile=base .. "/" .. config.transport.caFile
end
local app=require("application").new(config,{configDir=base,stateRoot=arg[3],programDir=arg[4],
    log=function(text) io.stderr:write(text,"\n") end})
local ok,result=pcall(app.run,app,arg[2])
app:close()
if not ok then error(result,0) end
io.write(json.encode(result),"\n")
