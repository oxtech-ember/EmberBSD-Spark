-- Installed Lua hooks are the small profile's compiled Hooks equivalent.
-- The installation supplies accepted {name,digest,hooks} records, never model
-- source or an acceptance flag. Hooks share the process and its privileges;
-- like Go native hooks, blocking operations must honor ctx.cancelled/deadlineMs.
-- Signatures: BeforeTurn({number,messages={{role,text}},note},ctx)->same shape;
-- BeforeTool({name,args=stringMap},ctx)->{allow,reason,replace,args=stringMap};
-- AfterTool(call,{text,isError},ctx)->{text,isError};
-- Call({args=stringMap},ctx)->{text,isError}. The loop owns exclusions for
-- terminal decisions and already approved actions, and records changedBy.
local json, core = require("json"), require("asenta.core")
local Mutators = {}
Mutators.__index = Mutators
local entryNames = {"Call", "BeforeTool", "AfterTool", "BeforeTurn"}
local function object(value) return type(value) == "table" and value ~= json.null end
local function map(value) return setmetatable(value or {}, {__jsontype="object"}) end
local function trim(value) return (value or ""):match("^%s*(.-)%s*$") end
local function copy(value)
    if not object(value) then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return setmetatable(result, getmetatable(value))
end
local function current(context) return type(context) == "function" and context() or context or {} end
local function detail(reason)
    return object(reason) and tostring(reason.message or reason.reason or "hook failed") or tostring(reason)
end
local function broken(record, entry, reason)
    error({reason="mutator_broken", mutator=record.name, entry=entry,
        message="Accepted mutator " .. record.name .. "." .. entry .. " failed: " .. detail(reason)}, 0)
end
local function same(a, b)
    if a == b then return true end
    if not object(a) or not object(b) then return false end
    for key, value in pairs(a) do if not same(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local function values(args)
    local out = map()
    if not object(args) then return out end
    for name, value in pairs(args) do
        if type(name) ~= "string" then return map() end
        if value ~= json.null then out[name] = type(value) == "string" and value or json.encode(value) end
    end
    return out
end
local function strings(args)
    assert(args == nil or object(args), "replacement arguments must be an object")
    for key, value in pairs(args or {}) do
        assert(type(key) == "string" and type(value) == "string", "replacement arguments must contain strings")
    end
    return args or map()
end
local function output(value)
    assert(object(value) and type(value.text) == "string", "output must contain text")
    assert(value.isError == nil or type(value.isError) == "boolean", "output isError must be boolean")
    return {text=value.text, isError=value.isError == true}
end

function Mutators.new(accepted, options)
    local self = setmetatable({records={}, options=options or {}}, Mutators)
    local seen = {}
    for _, record in ipairs(accepted or {}) do
        assert(type(record.name) == "string" and record.name ~= "" and not seen[record.name], "mutator names must be unique")
        assert(type(record.digest) == "string" and record.digest ~= "", "installed mutator needs its implementation digest")
        assert(object(record.hooks), "installed mutator needs a trusted hook table")
        local bound = copy(record)
        bound.entries = json.array()
        for _, entry in ipairs(entryNames) do
            local hook = bound.hooks[entry]
            assert(hook == nil or type(hook) == "function", "mutator entry must be a function: " .. entry)
            if hook then bound.entries[#bound.entries + 1] = entry end
        end
        assert(#bound.entries > 0, "mutator declares no entry point")
        seen[record.name], self.records[#self.records + 1] = true, bound
    end
    table.sort(self.records, function(a,b) return a.name < b.name end)
    return self
end

-- Contract validation runs inside the same protected call as the hook. Any
-- failure stops the attempt; returning the original input would fail open.
function Mutators:_invoke(record, entry, context, validate, ...)
    assert(not self.closed, "mutator shelf is closed")
    local ctx = {}
    for key, value in pairs(current(context or self.options.context)) do ctx[key]=value end
    local cancel = ctx.cancelled
    local timeout = entry == "Call" and (self.options.callTimeoutMs or 30000) or (self.options.timeoutMs or 5000)
    local deadline = math.min(ctx.deadlineMs or math.huge, core.monotonic_ms() + timeout)
    ctx.deadlineMs = deadline
    ctx.cancelled = function() return core.monotonic_ms() >= deadline or cancel and cancel() or false end
    local args = table.pack(...)
    local started = false
    local ok, result = pcall(function()
        assert(not ctx.cancelled(), "hook cancelled or deadline exceeded")
        args.n = args.n + 1; args[args.n] = ctx
        started = true
        local value = record.hooks[entry](table.unpack(args, 1, args.n))
        assert(not ctx.cancelled(), "hook cancelled or deadline exceeded")
        return validate(value)
    end)
    if not ok then
        if entry == "Call" then
            local checked, cancelled = pcall(ctx.cancelled)
            error({reason="mutator_call_failed", message=record.name .. ".Call: " .. detail(result),
                outcomeUnknown=started and (not checked or cancelled) or nil}, 0)
        end
        broken(record, entry, result)
    end
    return result
end

-- The default adapter accepts canonical messages only. Responses items require
-- explicit messageText(item)->role,text and withText(copy,text)->item adapters.
-- The adapter owns provider shape; hooks see no call IDs or attachment fields.
function Mutators:before_turn(number, messages, context)
    assert(not self.closed, "mutator shelf is closed")
    local out, changedBy = require("sequence").copy(messages), json.array()
    local read = self.options.messageText or function(message)
        assert(type(message.role) == "string" and type(message.content) == "string",
            "provider items require an explicit mutator message adapter")
        return message.role, message.content
    end
    local replace = self.options.withText or function(message, text) message.content=text; return message end
    assert((self.options.messageText == nil) == (self.options.withText == nil), "both message adapters are required")
    for _, record in ipairs(self.records) do
        if record.hooks.BeforeTurn then
            local original = json.array()
            for _, message in ipairs(out) do
                local role, text = read(message)
                assert(type(role) == "string" and type(text) == "string", "message adapter must return role and text")
                original[#original + 1] = {role=role, text=text}
            end
            local answer = self:_invoke(record, "BeforeTurn", context, function(value)
                assert(object(value) and object(value.messages) and #value.messages == #original,
                    "BeforeTurn must preserve the message count")
                local count = 0
                for index in pairs(value.messages) do
                    count=count+1
                    assert(type(index) == "number" and index%1 == 0 and index >= 1 and index <= #original,
                        "BeforeTurn messages must be an array")
                end
                assert(count == #original, "BeforeTurn messages must be dense")
                for index, message in ipairs(value.messages) do
                    assert(object(message) and message.role == original[index].role and type(message.text) == "string",
                        "BeforeTurn may change text, not message roles")
                end
                assert(value.note == nil or type(value.note) == "string", "BeforeTurn note must be text")
                return value
            end, {number=number, messages=copy(original), note=""})
            local changed = false
            for index, message in ipairs(answer.messages) do
                if message.text ~= original[index].text then out[index]=replace(copy(out[index]), message.text); changed=true end
            end
            local note = trim(answer.note)
            if note ~= "" then out[#out + 1]={role="system", content=note}; changed=true end
            if changed then changedBy[#changedBy + 1] = record.name end
        end
    end
    return out, changedBy
end

function Mutators:before_tool(call, context)
    assert(not self.closed, "mutator shelf is closed")
    local out, ruling = copy(call), {changedBy=json.array()}
    for _, record in ipairs(self.records) do
        if record.hooks.BeforeTool then
            local original = values(out.args)
            local verdict = self:_invoke(record, "BeforeTool", context, function(value)
                assert(object(value), "BeforeTool must return a verdict")
                assert(value.allow == nil or type(value.allow) == "boolean", "verdict allow must be boolean")
                assert(value.replace == nil or type(value.replace) == "boolean", "verdict replace must be boolean")
                assert(value.reason == nil or type(value.reason) == "string", "verdict reason must be text")
                if value.replace then strings(value.args) end
                return value
            end, {name=out.name, args=copy(original)})
            if not verdict.allow then
                local reason = trim(verdict.reason)
                ruling.refusal = (reason ~= "" and reason or "The mutator did not allow this call") .. " (" .. record.name .. ")"
                return out, ruling
            end
            if verdict.replace then
                local replaced = map()
                for name, value in pairs(verdict.args or {}) do
                    if original[name] == value then replaced[name]=copy(out.args[name]) else replaced[name]=value end
                end
                if not same(replaced, out.args) then
                    out.args = replaced
                    ruling.changedBy[#ruling.changedBy + 1] = record.name
                end
            end
        end
    end
    return out, ruling
end

-- Pass the exact model-visible answer, after secret redaction. In particular,
-- structured tool results must reach this method as their model-visible JSON.
function Mutators:after_tool(call, result, context)
    assert(not self.closed, "mutator shelf is closed")
    local out, changedBy = output(result), json.array()
    for _, record in ipairs(self.records) do
        if record.hooks.AfterTool then
            local answer = self:_invoke(record, "AfterTool", context, output,
                {name=call.name, args=values(call.args)}, copy(out))
            if not same(answer, out) then out=answer; changedBy[#changedBy + 1]=record.name end
        end
    end
    return out, changedBy
end

function Mutators:tools(context)
    assert(not self.closed, "mutator shelf is closed")
    local tools = json.array()
    for _, record in ipairs(self.records) do
        if record.hooks.Call then
            local name = record.toolName or "own." .. record.name
            tools[#tools + 1] = {name=name, group="workshop", description=record.description or "",
                class=record.class or (record.network and "external" or "exec"), program=record.digest,
                source=record.source or (record.network and name or ""), foreign=record.foreign == true,
                parameters=record.parameters or {type="object", properties=map()},
                invoke=function(args)
                    local result = self:_invoke(record, "Call", context, output, {args=values(args)})
                    return {content=json.array({{type="text", text=result.text}}), isError=result.isError}
                end}
        end
    end
    return tools
end

function Mutators:report()
    local out = json.array()
    for _, record in ipairs(self.records) do out[#out + 1]={name=record.name, digest=record.digest, entries=copy(record.entries)} end
    return out
end
function Mutators:close() self.records={}; self.closed=true end
return Mutators
