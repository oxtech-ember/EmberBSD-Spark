-- Full answers use the existing attachment upload contract. The workflow must
-- persist the tool result AFTER redaction/mutators, then issue a separate safe
-- upload effect. Replaying that effect must never invoke the tool again.
local json, fs, Client = require("json"), require("asenta.fs"), require("client")
local Documents = {}
local function copy(value)
    local out = {}; for key,item in pairs(value) do out[key]=item end; return out
end
local function nonempty(value) return type(value) == "string" and value ~= "" end
local function filename(word, fingerprint, extension)
    local stop = utf8.offset(word,81)
    if stop then word=word:sub(1,stop-1) end
    -- Leave room for the phrase and digest even when the caption uses four
    -- bytes per character. Do not split a UTF-8 sequence in a saved filename.
    if #word > 180 then word=word:sub(1,(utf8.offset(word,0,181) or 181)-1) end
    local name = "Whole answer of " .. word .. " " .. fingerprint
    name = name:gsub('[%z\1-\31\127/\\:*?"<>|]', " "):gsub("%s+", " "):gsub("^[ .]+", ""):gsub("[ .]+$", "")
    return name .. extension
end

-- Persist this value with the effect when title/provenance came from the live
-- registry. Its body, name, provenance and key are then fixed across restarts.
-- composed is the loop's existing unvouched result (composes OR echoes), not
-- whether the answer contains foreign text.
function Documents.prepare(task, call, result, context)
    local ctx = context or {}
    local ceiling = ctx.toolOutput or 24576
    if ceiling <= 0 then ceiling=24576 end
    if ctx.aside or not nonempty(result.whole) or #result.whole <= ceiling or result.attachment then return nil end
    local taskId = type(task) == "table" and (task.taskId or task.id) or task
    assert(nonempty(taskId), "task is required to keep a full answer")
    assert(type(ctx.composed) == "boolean", "the loop must supply the answer's composed provenance")
    local requestId = ctx.requestId
    if not requestId then
        assert(nonempty(ctx.stepId) and nonempty(call.id), "persisted step and call IDs are required for an attachment")
        requestId=ctx.stepId .. "/" .. call.id .. "/whole"
    end
    assert(nonempty(requestId), "attachment request ID is required")
    local isJSON = pcall(json.decode,result.whole)
    local word = ctx.title or ctx.nativeName or call.name or "tool"
    return {taskId=taskId, requestId=requestId, composed=ctx.composed, body=result.whole,
        filename=filename(word,fs.sha256(result.whole):sub(1,8),isJSON and ".json" or ".txt"),
        contentType=isJSON and "application/json" or "text/plain; charset=utf-8"}
end

local function permanent(err)
    if type(err) ~= "table" then return false end
    if err.reason == "no_storage" then return true end
    return err.status and err.status >= 400 and err.status < 500 and err.status ~= 408 and err.status ~= 429
end

function Documents.keep(client, task, call, result, context)
    local ctx = context or {}
    if result.attachment then return result end
    local upload = ctx.upload or Documents.prepare(task,call,result,ctx)
    if not upload then return result end
    assert(upload.body == result.whole, "prepared attachment does not match the saved tool answer")
    local out = copy(result)
    local ok, reply = pcall(function()
        assert(client, "no server is available to keep the full answer")
        local path = "/api/v1/tasks/" .. Client.escape(upload.taskId) .. "/attachments?filename=" ..
            Client.escape(upload.filename) .. "&requestId=" .. Client.escape(upload.requestId)
        if upload.composed then path=path .. "&composed=true" end
        return client:request("POST",path,nil,false,{rawBody=upload.body,
            headers={["Content-Type"]=upload.contentType},maxBytes=1024*1024})
    end)
    if not ok then
        -- Unknown outcomes and temporary server failures remain retryable with
        -- the same saved upload. A definitive refusal still lets the head
        -- reach the model, as Go keepWhole does, without a promised document.
        if client and not permanent(reply) then error(reply,0) end
        local err = type(reply) == "table" and reply or {message=tostring(reply)}
        out.attachmentError={reason=err.reason, status=err.status, message=err.message or "attachment refused"}
        out.output=(result.output or "") .. "\n\nThe full answer could not be attached: " .. out.attachmentError.message ..
            ". Its omitted contents are unavailable in this response."
        return out
    end
    local attachment = reply and reply.attachment
    assert(type(attachment) == "table" and nonempty(attachment.attachmentId) and nonempty(attachment.filename),
        "upload response is missing attachment metadata")
    out.attachment=attachment
    out.output=(result.output or "") .. "\n\nThe full answer is attached as " .. json.encode(attachment.filename) ..
        " (attachment " .. attachment.attachmentId .. ")."
    if nonempty(ctx.reader) then out.output=out.output .. " Read it with " .. ctx.reader .. "."
    else out.output=out.output .. " This profile has no document reader." end
    return out
end

-- main_static.go does not install toolset.Documents or a docstore. Preserve
-- that profile: neither a new read_document tool nor PDF/browser dependencies.
function Documents.tools() return json.array() end
return Documents
