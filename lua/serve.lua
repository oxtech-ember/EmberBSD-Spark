local directory=arg[0]:match("^(.*)/[^/]+$") or "."
package.path=directory .. "/?.lua;" .. package.path
local json, Scheduler = require("json"), require("scheduler")
local configPath, once, options, server = "agent.json", false, {}, nil
local language, acceptTools
local at=1
while arg[at] do
    local flag=arg[at]
    if flag=="--once" or flag=="-once" then once=true
    elseif flag=="--capabilities" or flag=="-capabilities" then io.write(json.encode(Scheduler.capabilities()),"\n"); return
    elseif flag=="--version" or flag=="-version" then io.write(require("version"),"\n"); return
    elseif flag=="--config" or flag=="-config" then at=at+1; configPath=assert(arg[at],"config path is required")
    elseif flag=="--server" or flag=="-server" then at=at+1; server=assert(arg[at],"server URL is required")
    elseif flag=="--lang" or flag=="-lang" then at=at+1; language=assert(arg[at],"language is required")
    elseif flag=="--accept-tools" or flag=="-accept-tools" then at=at+1; acceptTools=assert(arg[at],"MCP alias is required")
    elseif flag=="--state-root" then at=at+1; options.stateRoot=assert(arg[at],"state root is required")
    elseif flag=="--program-dir" then at=at+1; options.programDir=assert(arg[at],"program directory is required")
    elseif at==1 and flag:sub(1,1)~="-" then configPath=flag
    else error("Unknown option: " .. flag .. ". Usage: agent-lua serve.lua [config.json] [--once] [--state-root PATH] [--program-dir PATH]") end
    at=at+1
end
if acceptTools then
    local names=require("desktop").accept_tools(nil,acceptTools)
    io.write(json.encode(names),"\n")
    return
end
options.programDir=options.programDir or require("asenta.core").programDir
local state=os.getenv("OXTORG_LUA_STATE_ROOT")
if state and state~="" then options.stateRoot=options.stateRoot or state end
local file=assert(io.open(configPath,"rb"))
local config=json.decode(assert(file:read("*a")));file:close()
options.configDir=configPath:match("^(.*)/[^/]+$") or "."
if not options.stateRoot and not config.stateRoot then
    local mcp=os.getenv("OXTORG_MCP")
    if mcp and mcp~="" then options.stateRoot=mcp .. "/native-state" end
end
-- A role file names a language family, as in existing installations.
-- Built-in messages remain English until their catalogue is migrated.
if language and config.roleFile then
    local stem,extension=config.roleFile:match("^(.*)(%.[^./]+)$")
    local localized=(stem or config.roleFile) .. "." .. language .. (extension or "")
    local path=localized:sub(1,1)=="/" and localized or options.configDir .. "/" .. localized
    local role=io.open(path,"rb")
    if role then role:close();config.roleFile=localized end
end
if server then config.server.baseUrl=server end
if config.transport and config.transport.caFile and config.transport.caFile:sub(1,1)~="/" then
    config.transport.caFile=options.configDir .. "/" .. config.transport.caFile
end
options.log=function(message) require("asenta.core").log((config.name or "Asenta") .. ": " .. message) end
local schedulerOptions={log=options.log}
local core=require("asenta.core")
if os.getenv("OXTORG_SUPERVISED")=="1" and core.supervision then
    schedulerOptions.canceled=function()
        local state=core.supervision()
        return state.draining or state.stopped
    end
    schedulerOptions.sleep=function(milliseconds)
        local deadline=core.monotonic_ms()+milliseconds
        while not schedulerOptions.canceled() do
            local remaining=deadline-core.monotonic_ms()
            if remaining<=0 then return end
            core.sleep(math.min(remaining,100))
        end
    end
end
-- A service started before its network is up waits for the server. Only a
-- request that received no answer is repeated; a refusal still ends startup.
local Application=require("application")
local app
local wait=2000
while true do
    local created,result=pcall(Application.new,config,options)
    if created then app=result; break end
    local unanswered=type(result)=="table" and result.status==nil and
        tostring(result.message or ""):sub(1,10)=="transport:"
    if once or not unanswered then error(result,0) end
    if schedulerOptions.canceled and schedulerOptions.canceled() then return end
    options.log("Server is unreachable, retrying: " .. tostring(result))
    ;(schedulerOptions.sleep or core.sleep)(wait)
    wait=math.min(wait*2,60000)
end
local service
local ok, result=pcall(function()
    service=Scheduler.new(app,schedulerOptions)
    return service:run(once)
end)
if service then service:close() end
app:close()
if not ok then error(result,0) end
