-- Dense arrays backed by immutable JSON items. Copies share item files, not
-- mutable reference lists; reading an item never keeps its decoded text here.
local fs, json = require("asenta.fs"), require("json")
local Sequence = {}
local sequences = setmetatable({}, {__mode="k"})
local records = setmetatable({}, {__mode="k"})
local marker = "__asenta_sequence"
local mt = {__jsontype="array"}
local fields = {__jsontype="object"}
local readItem, writeItem
local function refsCopy(refs)
    local out=json.array();for i,ref in ipairs(refs) do out[i]=ref end;return out
end
local function validIndex(index)
    return type(index)=="number" and index>=1 and index%1==0
end

function Sequence.new(root, references)
    assert(root, "sequence root is required")
    local refs=refsCopy(references or {})
    for _,ref in ipairs(refs) do
        assert(type(ref)=="string" and #ref==64 and not ref:find("[^0-9a-f]"), "invalid sequence reference")
    end
    local value=setmetatable({},mt)
    sequences[value]={root=root,refs=refs}
    return value
end
function Sequence.is(value) return sequences[value]~=nil end
function Sequence.references(value) return refsCopy(assert(sequences[value],"expected a sequence").refs) end
function Sequence.empty_like(value)
    local stored=sequences[value]
    return stored and Sequence.new(stored.root) or {}
end
function Sequence.copy(value)
    local stored=sequences[value]
    if stored then return Sequence.new(stored.root,stored.refs) end
    local out=json.array();for i,item in ipairs(value or {}) do out[i]=item end;return out
end

-- Keep selected text/schema fields on disk while ordinary metadata and
-- handlers remain directly accessible. Assignment replaces only that field.
function Sequence.clone(value)
    local out={}
    for key,item in next,value or {} do out[key]=item end
    local stored=records[value]
    if stored then
        local refs={};for key,ref in pairs(stored.refs) do refs[key]=ref end
        records[out]={root=stored.root,refs=refs};setmetatable(out,fields)
    else setmetatable(out,getmetatable(value)) end
    return out
end
function Sequence.fields(root,value,names)
    local out=Sequence.clone(value)
    local stored=records[out] or {root=root,refs={}}
    assert(stored.root==root,"record belongs to another store")
    for _,key in ipairs(names) do
        local item=rawget(out,key)
        if item~=nil then stored.refs[key]=writeItem(root,item);rawset(out,key,nil) end
    end
    if not next(stored.refs) then records[out]=nil;return setmetatable(out,nil) end
    records[out]=stored
    return setmetatable(out,fields)
end
function fields.__index(value,key)
    local stored=records[value]
    if stored.refs[key] then return readItem(stored.root,stored.refs[key]) end
end
function fields.__newindex(value,key,item)
    records[value].refs[key]=nil;rawset(value,key,item)
end
function fields.__pairs(value)
    local rawKey,refKey,readingRefs=nil,nil,false
    return function()
        if not readingRefs then
            local item;rawKey,item=next(value,rawKey)
            if rawKey~=nil then return rawKey,item end
            readingRefs=true
        end
        refKey=next(records[value].refs,refKey)
        if refKey~=nil then return refKey,value[refKey] end
    end
end

-- Only persistence uses this descriptor. The network encoder iterates the
-- proxy as an array so the public server/model JSON contract stays unchanged.
local function transform(value, root, packing, seen)
    if type(value)~="table" or value==json.null then return value end
    if seen[value] then return seen[value] end
    if packing and Sequence.is(value) then
        local out={[marker]=1,refs=Sequence.references(value)};seen[value]=out;return out
    elseif packing and records[value] then
        local stored=records[value]
        local plain,refs={},{}
        for key,item in next,value do plain[key]=item end
        for key,ref in pairs(stored.refs) do refs[key]=ref end
        local out={[marker]=2,refs=refs};seen[value]=out
        out.value=transform(plain,root,true,seen)
        return out
    elseif not packing and rawget(value,marker)==1 then
        local out=Sequence.new(root,assert(value.refs,"sequence references are missing"));seen[value]=out;return out
    elseif not packing and rawget(value,marker)==2 then
        local out=transform(assert(value.value),root,false,seen)
        records[out]={root=root,refs=assert(value.refs)};seen[value]=out
        return setmetatable(out,fields)
    elseif not packing and rawget(value,marker)==0 then
        local literal=assert(value.value,"escaped sequence object is missing")
        local out=setmetatable({},getmetatable(literal));seen[value]=out
        for key,item in pairs(literal) do out[key]=transform(item,root,false,seen) end
        return out
    end
    local out=setmetatable({},getmetatable(value))
    -- Foreign JSON may use the same key. Escape that object, including literal
    -- escape wrappers, so only descriptors emitted for our proxies are read.
    local result=packing and rawget(value,marker)~=nil and {[marker]=0,value=out} or out
    seen[value]=result
    for key,item in pairs(value) do out[key]=transform(item,root,packing,seen) end
    return result
end
function Sequence.pack(value) return transform(value,nil,true,{}) end
function Sequence.unpack(root,value) return transform(value,root,false,{}) end

local function ordered(value,seen)
    if type(value)~="table" or value==json.null or seen[value] then return value end
    seen[value]=true
    local keys,meta={},{}
    for key,item in pairs(value) do keys[#keys+1]=key;ordered(item,seen) end
    table.sort(keys,function(a,b) return type(a)==type(b) and a<b or type(a)<type(b) end)
    for key,item in pairs(getmetatable(value) or {}) do meta[key]=item end
    meta.__jsonorder=keys
    return setmetatable(value,meta)
end

function mt.__len(value) return #sequences[value].refs end
readItem=function(root,ref)
    assert(type(ref)=="string" and #ref==64 and not ref:find("[^0-9a-f]"),"invalid item reference")
    local path="sequences/" .. ref .. ".json"
    local info=assert(root:stat(path))
    local text=assert(root:read(path,info.size))
    assert(fs.sha256(text)==ref,"sequence item hash mismatch")
    return Sequence.unpack(root,json.decode(text))
end
writeItem=function(root,item)
    local text=json.encode(ordered(Sequence.pack(item),{}))
    local ref=fs.sha256(text)
    local path="sequences/" .. ref .. ".json"
    if not root:stat(path) then assert(root:write(path,text)) end
    return ref
end
function mt.__index(value,index)
    if not validIndex(index) then return nil end
    local stored=sequences[value]
    if stored.refs[index] then return readItem(stored.root,stored.refs[index]) end
end
function mt.__newindex(value,index,item)
    local stored=sequences[value]
    assert(validIndex(index) and index<=#stored.refs+1,"sequence assignment must keep a dense array")
    if item==nil then
        assert(index==#stored.refs,"only the last sequence item can be removed")
        stored.refs[index]=nil;return
    end
    -- dkjson's per-object order keeps the hash independent of Lua hash seeds.
    -- Only the copied, packed item receives ordering metadata.
    stored.refs[index]=writeItem(stored.root,item)
end
function mt.__pairs(value) return ipairs(value) end

return Sequence
