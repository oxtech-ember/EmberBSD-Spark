-- Installation-owned adapters use the same connection interface as MCP.
-- Only local configuration selects code; server rig switches select aliases.
local json,fs=require("json"),require("asenta.fs")
local M={}
function M.connect(spec,options)
    options=options or {}
    local missing=json.array()
    local connection
    local ok,why=pcall(function()
        assert(type(spec.alias)=="string" and spec.alias~="", "native alias is required")
        assert(type(spec.module)=="string" and spec.module~="", "native module is required")
        assert(not spec.command and not spec.url, "native module cannot also select an MCP transport")
        local settings={};for key,value in pairs(options) do settings[key]=value end
        local env={};for key,value in pairs(spec.env or {}) do env[key]=value end
        for key,variable in pairs(spec.envFrom or {}) do
            local value=os.getenv(variable)
            -- Empty is a meaningful installation policy, e.g. no journal units.
            if value==nil then missing[#missing+1]=variable else env[key]=value end
        end
        table.sort(missing)
        assert(#missing==0,"missing environment: " .. table.concat(missing,", "))
        settings.env=env
        connection=require(spec.module).connect(spec,settings)
        local offered=connection:tools()
        local program=fs.sha256(require("version") .. "\n" .. spec.module)
        for _,tool in ipairs(offered) do tool.program=program end
    end)
    if ok then return connection end
    if connection then pcall(connection.close,connection) end
    return {
        tools=function() return json.array() end,
        close=function() end,
        report=function() return {alias=spec.alias,name=spec.module,connected=false,
            tools=0,reason=tostring(why),missing=missing,declared=json.array(),held=json.array()} end,
    }
end
return M
