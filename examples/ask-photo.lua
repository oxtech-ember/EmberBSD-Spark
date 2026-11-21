-- Ask the configured Spark model about one accepted workshop photo.
-- The seekable PNG input stays open while Client uploads the JSON body.
local Client = require("client")
local Model = require("model")
local json = require("json")

local function ask(configPath, imagePath, guide, ordinal, heading, instruction)
    assert(instruction and tonumber(ordinal) and guide ~= "" and heading ~= "",
        "expected config, PNG file or -, guide, step number, heading and instruction")
    local cfg <close> = assert(io.open(configPath, "rb"))
    local config = json.decode(assert(cfg:read(65537)))
    assert(cfg:seek("end") <= 65536, "configuration is too large")
    config.server = config.server or {}
    assert(type(config.model) == "table" and type(config.model.alias) == "string", "model.alias is required")
    config.transport = config.transport or {}
    local ca = config.transport.caFile
    if ca and ca ~= "" and ca:sub(1,1) ~= "/" then
        config.transport.caFile = (configPath:match("^(.*[/])") or "./") .. ca
    end
    config.transport.maxBytes = math.min(config.transport.maxBytes or 32768, 65536)
    config.transport.maxUploadBytes = math.min(config.transport.maxUploadBytes or 3*1024*1024, 3*1024*1024)
    config.model.catalogueMaxBytes = math.min(config.model.catalogueMaxBytes or 65536, config.transport.maxBytes)
    config.model.maxAnswer = math.min(config.model.maxAnswer or 220, 512)

    local owned <close> = imagePath ~= "-" and assert(io.open(imagePath, "rb")) or nil
    local photo = owned or io.stdin
    assert(photo:seek("set", 0))
    assert(photo:read(8) == "\137PNG\r\n\26\n", "expected PNG photo")
    local question = ("Guide: %s\nStep %s: %s\nInstruction: %s\nWhat can you see in this photo " ..
        "that helps with this step? Say when the relevant detail is unclear."):format(guide, ordinal, heading, instruction)
    local input = json.array({
        {role="developer", content="Use short plain English with ASCII characters, at most three sentences."},
        {role="user", content=json.array({
            {type="input_text", text=question},
            {type="input_image", image_url=json.data_uri(photo, "image/png", 2*1024*1024)}
        })}
    })
    local reply = Model.new(config, Client.new(config)):request(input, {}, nil, {singleAttempt=true})
    local answer = reply.answer:gsub("%s+", " "):match("^%s*(.-)%s*$")
    assert(#answer > 0 and #answer <= 2048 and not answer:find("[^ -~]"), "answer exceeds display limits")
    assert(io.write(answer, "\n"))
end

local ok, err = pcall(ask, table.unpack(arg, 1, #arg))
if not ok then
    -- Provider error bodies may include echoed request data. Keep them private.
    local status = type(err) == "table" and tonumber(err.status)
    io.stderr:write(status and ("Model HTTP " .. status .. "\n") or "Photo request failed\n")
    os.exit(1)
end
