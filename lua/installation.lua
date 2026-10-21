-- Resolve the server's switches against installation-owned passports. Local
-- command and environment mappings win; the server only names an alias.
local json,fs=require("json"),require("asenta.fs")
local M={}
function M.rig(config,client,options)
    options=options or {}
    local passports,byAlias={},{}
    local root=options.programDir and fs.root(options.programDir,false)
    if root then
        for _,entry in ipairs(root:list() or {}) do
            local alias=entry.name:match("^oxtorg%-mcp%-(.+)%.passport%.json$")
            if alias and entry.kind=="file" then
                local ok,passport=pcall(function()return json.decode(assert(root:read(entry.name)))end)
                if ok then passport.alias=alias;byAlias[alias]=passport;passports[#passports+1]=passport end
            end
        end
        root:close()
    end
    local specs,localSpecs=json.array(),{}
    for _,spec in ipairs(config.mcp or {}) do
        specs[#specs+1]=spec;localSpecs[spec.alias]=spec
        if spec.module then
            local native={alias=spec.alias,name=spec.module,title=spec.alias,env=json.array()}
            for _,variable in pairs(spec.envFrom or {}) do
                native.env[#native.env+1]={name=variable,required=true}
            end
            -- The installation's native implementation replaces its old passport.
            for i=#passports,1,-1 do
                if passports[i].alias==spec.alias then table.remove(passports,i) end
            end
            passports[#passports+1]=native;byAlias[spec.alias]=native
        end
    end
    local ok,value=pcall(client.request,client,"GET","/api/v1/me/rig")
    if not ok then
        if options.log then options.log("Server rig unavailable; keeping local MCP configuration.") end
        return specs,passports
    end
    for _,switch in ipairs(value.rig or {}) do
        local found
        for i,spec in ipairs(specs) do if spec.alias==switch.alias then found=i;break end end
        if not switch.enabled then if found then table.remove(specs,found) end
        elseif not found and localSpecs[switch.alias] then
            specs[#specs+1]=localSpecs[switch.alias]
        elseif not found and byAlias[switch.alias] then
            local passport,env=byAlias[switch.alias],{}
            for _,item in ipairs(passport.env or {}) do
                if item.required or (os.getenv(item.name) or "")~="" then env[item.name]=item.name end
            end
            specs[#specs+1]={alias=switch.alias,command=options.programDir .. "/oxtorg-mcp-" .. switch.alias,envFrom=env}
        end
    end
    return specs,passports
end
return M
