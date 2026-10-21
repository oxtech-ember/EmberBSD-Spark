-- Read the transitional inline format during a one-time local migration.
-- Current manifests refer to immutable files and contain no source text.
local json = require("json")
local Codec = {}
local format = "shared-worktree-sources-v1"
local function sources(state,convert)
    for _,name in ipairs({"snapshot","commitBase"}) do
        for _,file in ipairs(state[name].files) do file.text=convert(file.text) end
    end
    for _,name in ipairs({"files","observed","checkpoint"}) do
        local keys={}
        for path in pairs(state[name]) do keys[#keys+1]=path end
        table.sort(keys)
        for _,path in ipairs(keys) do state[name][path]=convert(state[name][path]) end
    end
    return state
end
function Codec.unpack(value)
    if type(value) ~= "table" or value.format~=format then return value end
    return sources(value.state,function(id)
        local text=value.texts[id]
        assert(type(id)=="number" and id%1==0 and type(text)=="string","draft source reference is missing")
        return text
    end)
end
return Codec
