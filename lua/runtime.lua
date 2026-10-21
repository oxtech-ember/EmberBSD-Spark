-- One durable attempt. The scheduler and adapters are injected; this module
-- knows neither tool names nor server endpoints. Persist before invoking IO.
local json = require("json")
local machine = require("machine")
local Sequence = require("sequence")
local Runtime = {}
Runtime.__index = Runtime
local copy = Sequence.clone

-- Old checkpoints and callers can still supply ordinary arrays. Convert only
-- transcript slots; effect parameters and public JSON objects keep their shape.
local function persist(root,name,state)
    local converted={}
    local function sequence(value)
        if type(value)~="table" or value==json.null or Sequence.is(value) then return value end
        if converted[value] then return converted[value] end
        local out=Sequence.new(root);converted[value]=out
        for i,item in ipairs(value) do out[i]=item end
        return out
    end
    state.sequenceSchema=1
    state.data=Sequence.fields(root,state.data,{"role"})
    state.data.input=sequence(state.data.input)
    state.data.definitions=sequence(state.data.definitions)
    state.data.selectedSkills=sequence(state.data.selectedSkills)
    for _,key in ipairs({"compactJob","compacted"}) do
        local value=state.data[key]
        if type(value)=="table" and value~=json.null and value.input then
            value=copy(value);value.input=sequence(value.input);state.data[key]=value
        end
    end
    if state.pending and state.pending.kind=="model" then
        state.pending=copy(state.pending)
        state.pending.input=copy(state.pending.input)
        state.pending.input.messages=sequence(state.pending.input.messages)
        state.pending.input.definitions=sequence(state.pending.input.definitions)
    end
    assert(root:write(name .. ".json",json.encode(Sequence.pack(state))))
    return state
end

function Runtime.open(root, name, initial, handlers)
    local lock = assert(root:lock(name .. ".lock"))
    local ok, state = pcall(function()
        local saved = root:stat(name .. ".json")
        if saved then
            local restored=json.decode(assert(root:read(name .. ".json", saved.size)))
            if restored.sequenceSchema==1 then restored=Sequence.unpack(root,restored) end
            return persist(root,name,restored)
        end
        assert(initial, "attempt state is missing")
        local first = machine.new(assert(initial.taskId), assert(initial.attemptId))
        first.data = initial.data or {}
        return persist(root,name,first)
    end)
    if not ok then lock:close(); error(state, 0) end
    return setmetatable({root=root, name=name, state=state, handlers=handlers, lock=lock}, Runtime)
end

function Runtime:transition(event, changes)
    local next, effects = machine.transition(self.state, event)
    next.data = copy(event.data or self.state.data)
    for k, v in pairs(changes or {}) do next.data[k] = v end
    self.state = persist(self.root,self.name,next)
    if effects[1] then effects[1]=self.state.pending end
    return effects
end

function Runtime:execute(effect)
    local handler = assert(self.handlers[effect.kind], "missing effect handler: " .. effect.kind)
    local ok, value = pcall(handler, effect.input, effect, self.state.data)
    if ok then
        self:transition({type="completed", id=effect.id, value=value},
            self.handlers.checkpoint and self.handlers.checkpoint())
    else
        local error = type(value) == "table" and value or {message=tostring(value)}
        local certainty=error.certainty
        if error.status and error.status>=400 and error.status<500 then certainty="not_started" end
        self:transition({type="failed", id=effect.id, error=error,
            reason=error.reason, certainty=certainty})
    end
    return self.state
end

function Runtime:issue(effect, changes)
    local effects = self:transition({type="issue", effect=effect}, changes)
    return self:execute(effects[1])
end

function Runtime:advance(phase, changes)
    self:transition({type="advance", phase=phase}, changes)
    return self.state
end

function Runtime:resume()
    local effects = self:transition({type="resume"})
    if effects[1] then return self:execute(effects[1]) end
    return self.state
end

function Runtime:finish(outcome,data)
    self:transition({type="finish", outcome=outcome,data=data})
    return self.state
end

function Runtime:recover(phase, changes)
    self:transition({type="recover",phase=phase},changes)
end

function Runtime:close()
    if self.lock then assert(self.lock:close()); self.lock = nil end
end

return Runtime
