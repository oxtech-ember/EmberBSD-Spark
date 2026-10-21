-- A standalone entry point for installed callers of the native ELM327 reader.
local directory=arg[0]:match("^(.*)/[^/]+$") or "."
package.path=directory.."/?.lua;"..package.path
local json=require("json")
local options={}
local ok,result=pcall(function()
    local i=1
    while i<=#arg do
        local key=arg[i]
        if key=="--help" then
            io.write("Usage: agent-lua obd-read.lua --address MAC --channel N [--live DIRECTORY]\n")
            return false
        end
        assert(key=="--address" or key=="--channel" or key=="--live", "unknown option: "..key)
        options[key]=assert(arg[i+1],"missing value for "..key); i=i+2
    end
    local connection=require("bluetooth").connect({alias="bluetooth"},{env={VOICE_KB_LIVE=options["--live"] or os.getenv("VOICE_KB_LIVE")}})
    return connection:call("obd_read",{address=options["--address"],channel=tonumber(options["--channel"])}).data
end)
if not ok then
    io.write(json.encode({time=os.date("%Y-%m-%dT%H:%M:%S%z"),adapter_addr=options["--address"],
        values=setmetatable({},{__jsontype="object"}),error=tostring(result)}),"\n")
    os.exit(2)
end
if result then io.write(json.encode(result),"\n") end
