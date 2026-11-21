local codec = require("dkjson")
local base64 = require("base64")
local M = {null = codec.null}
function M.array(value) return setmetatable(value or {}, {__jsontype = "array"}) end
function M.decode(text)
    local value, position, err = codec.decode(text, 1, codec.null)
    assert(not err, err)
    assert(not text:sub(position):find("%S"), "trailing JSON data")
    return value
end
function M.encode(value) return assert(codec.encode(value)) end

-- Explicit arrays may be lazy sequences: only #value and value[index] are
-- needed. Ordinary tables retain dkjson's dense/small-sparse array spelling.
local function array_length(value)
    local kind=(getmetatable(value) or {}).__jsontype
    if kind == "array" then return #value end
    if kind == "object" then return nil end
    local maximum,count,declared=0,0,0
    for key,item in pairs(value) do
        if key == "n" and type(item) == "number" then declared=item; maximum=math.max(maximum,item)
        elseif type(key) ~= "number" or key < 1 or key%1 ~= 0 then return nil
        else maximum=math.max(maximum,key); count=count+1 end
    end
    if maximum > 10 and maximum > declared and maximum > count*2 then return nil end
    return maximum
end

-- A seekable, borrowed attachment. The caller keeps it open and its
-- contents stable through completion of the HTTP request.
local dataURI = {}
function M.data_uri(file, mediaType, limit)
    assert(type(mediaType) == "string" and mediaType:match("^[a-z0-9.+-]+/[a-z0-9.+-]+$"), "invalid media type")
    assert(math.type(limit) == "integer" and limit > 0, "attachment requires a byte limit")
    local size = assert(file:seek("end"))
    assert(size > 0 and size <= limit and size <= (math.maxinteger // 4 - 1) * 3, "invalid attachment size")
    return setmetatable({file=file, size=size, prefix='"data:' .. mediaType .. ';base64,'}, dataURI)
end

local function uri_fragments(item, measuring)
    coroutine.yield(item.prefix)
    if measuring then
        coroutine.yield(((item.size + 2) // 3) * 4)
    else
        assert(item.file:seek("set", 0))
        local remaining = item.size
        while remaining > 0 do
            local n = math.min(remaining, 3072)
            local bytes = assert(item.file:read(n), "short attachment")
            assert(#bytes == n, "short attachment")
            coroutine.yield(base64(bytes))
            remaining = remaining - n
        end
        local extra, err = item.file:read(1)
        assert(not err and extra == nil, "attachment changed length")
    end
    coroutine.yield('"')
end

local function fragments(value, measuring)
    return coroutine.wrap(function()
        local active={}
        local function emit(item)
            if type(item) ~= "table" or item == M.null then coroutine.yield(M.encode(item)); return end
            if getmetatable(item) == dataURI then return uri_fragments(item, measuring) end
            assert(not active[item], "JSON table contains a reference cycle")
            active[item]=true
            local length=array_length(item)
            if length then
                coroutine.yield("[")
                for index=1,length do
                    if index>1 then coroutine.yield(",") end
                    emit(item[index])
                end
                coroutine.yield("]")
            else
                coroutine.yield("{")
                local first=true
                for key,child in pairs(item) do
                    assert(type(key) == "string" or type(key) == "number", "JSON object needs string or number keys")
                    if not first then coroutine.yield(",") end
                    first=false
                    coroutine.yield(M.encode(tostring(key)))
                    coroutine.yield(":")
                    emit(child)
                end
                coroutine.yield("}")
            end
            active[item]=nil
        end
        emit(value)
    end)
end

-- The value/proxy must remain repeatable until upload finishes: the first
-- traversal counts bytes, the second emits them. No encoded document is kept.
function M.reader(value)
    local length=0
    for piece in fragments(value, true) do
        local count=type(piece) == "number" and piece or #piece
        assert(count <= math.maxinteger-length, "encoded JSON is too large")
        length=length+count
    end
    local nextPiece=fragments(value)
    local piece,at,finished="",1,false
    local function read(maxBytes)
        assert(type(maxBytes) == "number" and maxBytes%1 == 0 and maxBytes>0, "JSON reader needs a positive byte count")
        if finished then return nil end
        local parts,size={},0
        while size < maxBytes do
            if at > #piece then
                piece=nextPiece()
                if piece == nil then finished=true; break end
                at=1
            end
            local take=math.min(maxBytes-size,#piece-at+1)
            parts[#parts+1]=piece:sub(at,at+take-1)
            at,size=at+take,size+take
        end
        if size == 0 then return nil end
        return table.concat(parts)
    end
    return read,length
end
return M
