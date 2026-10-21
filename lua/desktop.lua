-- Human-only desktop commands. They use local state, never executor credentials
-- or network configuration, and cannot be reached through the tool registry.
local json,fs=require("json"),require("asenta.fs")
local M={}
local function object(value)
    return type(value)=="table" and value~=json.null and (getmetatable(value) or {}).__jsontype~="array"
end

function M.accept_tools(directory,alias)
    directory=directory or os.getenv("OXTORG_MCP")
    assert(type(directory)=="string" and directory~="","OXTORG_MCP is not set; no acceptance directory")
    assert(type(alias)=="string" and #alias>=1 and #alias<=64 and
        alias:match("^[A-Za-z0-9._-]+$") and alias:find("[^.]"),"invalid MCP server alias")
    local root=assert(fs.root(directory,false))
    local ok,result=pcall(function()
        local name="accepted/" .. alias .. ".json"
        local kept=json.decode(assert(root:read(name,4*1024*1024),"no accepted tool list for " .. alias))
        assert(object(kept) and type(kept.server)=="string" and kept.server~="","invalid MCP acceptance record")
        if kept.accepted==nil or kept.accepted==json.null then
            kept.accepted=setmetatable({},{__jsontype="object"})
        end
        if kept.pending==nil or kept.pending==json.null then
            kept.pending=setmetatable({},{__jsontype="object"})
        end
        assert(object(kept.accepted) and object(kept.pending),"invalid MCP declaration maps")
        local names=json.array()
        for tool,declaration in pairs(kept.pending) do
            assert(type(tool)=="string" and object(declaration) and declaration.name==tool,
                "invalid pending MCP declaration")
            kept.accepted[tool]=declaration
            names[#names+1]=tool
        end
        table.sort(names)
        kept.pending=nil
        assert(root:write(name,json.encode(kept)))
        return names
    end)
    root:close()
    if not ok then error(result,0) end
    return result
end
return M
