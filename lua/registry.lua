-- Tool declarations own their class, source, program and foreign-text metadata.
-- This registry maps names and shapes answers; the workflow owns authority,
-- secret redaction and attachment storage. Raw answers remain available to it.
local json = require("json")
local Sequence = require("sequence")
local Registry = {}
Registry.__index = Registry
local classes = {read=true, write_local=true, exec=true, attended=true, external=true, physical=true}

function Registry.modelName(native)
    local pieces = {}
    for _, code in utf8.codes(native) do
        pieces[#pieces + 1] = code < 128 and string.char(code):match("[A-Za-z0-9_-]") or "_"
    end
    return table.concat(pieces):gsub("^_+", ""):gsub("_+$", ""):sub(1, 64)
end

function Registry.new(options)
    return setmetatable({byModel={}, byNative={}, root=(options or {}).root,
        toolOutput=(options or {}).toolOutput or 24 * 1024}, Registry)
end

function Registry:add(tool)
    assert(type(tool.name) == "string", "tool name must be a string")
    local name = Registry.modelName(tool.name)
    assert(name ~= "", "tool name has no name for the model")
    assert(classes[tool.class], "unknown tool class: " .. tostring(tool.class))
    assert(type(tool.invoke) == "function", "tool must declare invoke(args)")
    assert(not self.byNative[tool.name], "tool already exists: " .. tool.name)
    local other = self.byModel[name]
    assert(not other, "tool names collide for the model: " .. tool.name .. " / " .. ((other or {}).name or "") .. " -> " .. name)
    local registered = self.root and Sequence.fields(self.root,tool,{"description","parameters","inputSchema"}) or Sequence.clone(tool)
    registered.modelName, registered.foreign = name, tool.foreign == true
    registered.program, registered.source = tool.program or "", tool.source or ""
    self.byNative[tool.name], self.byModel[name] = registered, registered
    return registered
end

function Registry:find(modelName) return self.byModel[modelName] end

function Registry:definition(modelName)
    local tool=self:find(modelName)
    if tool then return {type="function",name=tool.modelName,description=tool.description or "",
        parameters=tool.parameters or tool.inputSchema or {type="object"}} end
end

-- Shared by lazy declarations and skill summaries, as in loop/declarations.go.
-- A full stop before a numbered section is an abbreviation, not a sentence.
function Registry.firstSentence(text)
    for at,mark in text:gmatch("()([.!?])") do
        local rest=text:sub(at+1)
        if not (mark=="." and rest:match("^ +%d")) and
            (rest=="" or rest:sub(1,1)==" " or rest:sub(1,1)=="\n") then return text:sub(1,at) end
    end
    return text
end

local function foldedDescription(description)
    local head=Registry.firstSentence(description:gsub("%s+"," "):match("^%s*(.-)%s*$"))
    if utf8.len(head)>200 then head=head:sub(1,utf8.offset(head,201)-1):gsub("[ ,;:]+$","") .. "…" end
    return head .. " Declared short: before the first call, ask describe_tool for the full description and the arguments, by this name."
end

-- No argument returns the full inventory. An unfolding map returns the model's
-- declarations and whether anything is still folded; the runner persists it.
function Registry:definitions(unfolded)
    local names, definitions, folded = {}, self.root and Sequence.new(self.root) or json.array(), false
    for name in pairs(self.byNative) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local tool = self.byNative[name]
        local definition=self:definition(tool.modelName)
        if unfolded and not unfolded[tool.modelName] and #definition.description+#json.encode(definition.parameters)>2048 then
            definition.description=foldedDescription(definition.description)
            definition.parameters={type="object",properties=setmetatable({}, {__jsontype="object"}),additionalProperties=true}
            folded=true
        end
        definitions[#definitions + 1] = definition
    end
    return definitions, folded
end

local function describe(value)
    return value.name or value.uri or value.mimeType or "unnamed"
end

local function object(value)
    return type(value) == "table" and value ~= json.null
end

local function shape(raw)
    if type(raw) == "string" then return raw, false end
    if raw == nil then return "The tool answered with nothing: no text, file, or structure.", false end
    if not object(raw) or (raw.content == nil and raw.structuredContent == nil and
        raw.isError == nil and raw.resultType == nil) then return json.encode(raw), false end
    local lines = {}
    for _, part in ipairs(raw.content or {}) do
        if part.type == "text" then lines[#lines + 1] = part.text or ""
        elseif part.type == "resource" and object(part.resource) then
            local resource = part.resource
            lines[#lines + 1] = "Resource " .. describe(resource) .. ":"
            lines[#lines + 1] = resource.blob and "Binary resource retained; not read." or resource.text or ""
        elseif part.type == "resource_link" then
            lines[#lines + 1] = "Resource link " .. describe(part) .. " " .. (part.uri or "") .. "; not read."
        else
            lines[#lines + 1] = "Content of type " .. tostring(part.type) .. " (" .. describe(part) .. "); not read."
        end
    end
    local text = table.concat(lines, "\n")
    if raw.resultType == "input_required" then
        return "The tool asks for clarification; continuation is unavailable. " .. text, true
    end
    if raw.structuredContent ~= nil and raw.structuredContent ~= json.null then
        text = json.encode(raw.structuredContent)
    end
    if text == "" then text = "The tool answered with nothing: no text, file, or structure." end
    return text, raw.isError == true
end

-- Keep complete JSON fields, including small fields after a large one. A single
-- nested object may be unfolded once, as in loop/answer.go; arrays stay text.
local function cutObject(value, room, nested)
    if not object(value) or #value > 0 or (getmetatable(value) or {}).__jsontype == "array" then return end
    local keys, kept, dropped, largest = {}, {}, json.array(), nil
    for key in pairs(value) do
        if type(key) ~= "string" then return end
        keys[#keys + 1] = key
    end
    table.sort(keys)
    local left = room
    for _, key in ipairs(keys) do
        local size = #json.encode(key) + #json.encode(value[key]) + 2
        if size <= left then kept[key], left = value[key], left - size
        elseif not nested and object(value[key]) and (not largest or size > largest.size) then
            largest = {key=key, size=size}
        end
    end
    if largest and room - left < room / 2 then
        local inner = cutObject(value[largest.key], left - #json.encode(largest.key) - 2, true)
        if inner then kept[largest.key] = inner end
    end
    for _, key in ipairs(keys) do if kept[key] == nil then dropped[#dropped + 1] = key end end
    if #dropped == 0 and not largest then return end
    if #dropped > 0 then kept._dropped = dropped end
    return kept
end

local function head(text, limit)
    if limit == 0 then limit = 24 * 1024 end
    if #text <= limit then return text end
    local ok, value = pcall(json.decode, text)
    local kept = ok and cutObject(value, limit - 1024)
    local shortened = kept and json.encode(kept)
    if not shortened or #shortened > limit then
        local stop = limit
        while stop > 0 and text:byte(stop + 1) and text:byte(stop + 1) >= 128 and text:byte(stop + 1) < 192 do
            stop = stop - 1
        end
        shortened = text:sub(1, stop)
    end
    return shortened .. "\n\nThe answer was cut (" .. #shortened .. " of " .. #text ..
        " bytes shown). Missing fields are not evidence of absence."
end
Registry.head=head

function Registry:invoke(call)
    local tool = self:find(call.name)
    local result = {tool=tool, foreign=tool and tool.foreign or false, error=false}
    local ok, raw = pcall(function()
        assert(tool, "unknown tool: " .. tostring(call.name))
        if call.error then error(call.error, 0) end
        return tool.invoke(call.args or {})
    end)
    result.raw = raw
    local shaped, output, failed = pcall(shape, raw)
    if not ok or not shaped then
        local why = not ok and raw or output
        output = "Tool error: " .. (object(why) and tostring(why.message or why.error or why.reason or "invalid tool result") or tostring(why))
        failed = true
    end
    result.output, result.whole, result.error = head(output, self.toolOutput), output, failed
    return result
end

return Registry
