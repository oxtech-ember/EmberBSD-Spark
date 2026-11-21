package.path = "lua/?.lua;" .. package.path
local json = require("json")
local b64 = require("base64")
local function encode(value, chunk)
    local read, size = json.reader(value)
    local result = {}
    repeat
        local piece = read(chunk)
        if piece == nil then break end
        assert(#piece > 0 and #piece <= chunk)
        result[#result+1] = piece
    until false
    local wire = table.concat(result)
    assert(#wire == size)
    return json.decode(wire)
end
assert(b64("f") == "Zg==" and b64("fo") == "Zm8=" and b64("foo") == "Zm9v")
for _, n in ipairs({1, 2, 3, 3071, 3072, 3073, 6145}) do
    local f <close> = assert(io.tmpfile())
    local bytes = ("\000\255\128a"):rep(n // 4 + 1):sub(1, n)
    assert(f:write(bytes))
    local uri = json.data_uri(f, "image/png", n)
    for _, chunk in ipairs({1, 257, 16384}) do
        local part = encode({url=uri}, chunk)
        assert(part.url == "data:image/png;base64," .. b64(bytes))
    end
    assert(not pcall(json.data_uri, f, 'image/"bad', n))
    if n > 1 then assert(not pcall(json.data_uri, f, "image/png", n-1)) end
    assert(f:seek("end") and f:write("x"))
    assert(not pcall(encode, {url=uri}, 17))
end

-- One accepted photo names one model and authorizes one POST, even when the
-- general task profile has a spare alias and the gateway refuses the turn.
local requests = {}
local fake = {}
function fake:request(method, path, body)
    if method == "GET" then return {data={}} end
    requests[#requests+1] = body.model
    error({status=403,body={},message="refused"})
end
local model = require("model").new({model={alias="selected",fallback="spare"}}, fake)
assert(not pcall(model.request, model, {}, {}, nil, {singleAttempt=true}))
assert(#requests == 1 and requests[1] == "selected")

local http = require("asenta.http")
for _, test in ipairs({
    {maxBytes=8, body="123456789"},
    {maxBytes=128, maxUploadBytes=8, bodyReader=function() error("must not read") end, bodyBytes=9}
}) do
    test.method, test.url = "POST", "http://127.0.0.1/"
    local ok, err = pcall(http.request, test)
    assert(not ok and tostring(err):find("upload limit", 1, true))
end
print("Photo streaming, attachment bounds and single-request routing passed")
