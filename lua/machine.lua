-- Pure attempt transitions. Persist the returned state before running effects.
-- Inputs, values and pending effects are immutable; only the state is copied.
-- issue{effect={kind,input,next,replay?}} waits for a matching completed{id,value}
-- or failed{id,error,certainty,reason?}. Resume repeats delivery/safe effects;
-- other effects have an unknown outcome after restart and are never replayed.
-- A known not_started failure parks with its reason; an unknown model/tool
-- parks with outcome=unknown_<kind>_outcome and keeps pending for inspection.
-- stop{reason?} cancels; finish{outcome} ends the attempt. No tool-specific states,
-- IO, clocks, permissions or coroutine continuations belong in this module.
local M = {}
local replay = {append="delivery", read="safe", lease="safe"}

local function copy(value)
    local result = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

local function repeatable(effect)
    return effect.replay == "delivery" or effect.replay == "safe"
end

local function unknown(state)
    state.mode = "parked"
    state.certainty = "unknown"
    state.outcome = "unknown_" .. state.pending.kind .. "_outcome"
    state.reason = state.outcome
end

function M.new(taskId, attemptId)
    return {schema=1, mode="active", phase="prepare", taskId=taskId,
        attemptId=attemptId, seq=0}
end

function M.transition(state, event)
    local next = copy(state)
    local effects = {}
    if state.mode == "done" then return next, effects end

    if event.type == "stop" or event.type == "finish" then
        next.mode, next.pending = "done", nil
        next.outcome = event.type == "stop" and "canceled" or event.outcome
        next.reason = event.reason
        return next, effects
    end

    if event.type == "recover" then
        assert(state.mode == "parked", "recovery requires a parked attempt")
        next.mode, next.phase, next.pending = "active", event.phase, nil
    elseif event.type == "advance" then
        assert(state.mode == "active", "a phase change requires an active attempt")
        next.phase = assert(event.phase, "phase is required")
    elseif event.type == "issue" then
        assert(state.mode == "active", "an effect requires an active attempt")
        next.seq = state.seq + 1
        local effect = copy(event.effect)
        effect.id = state.attemptId .. "/" .. next.seq
        effect.replay = effect.replay or replay[effect.kind] or "never"
        next.mode, next.pending, next.last = "waiting", effect, nil
        next.reason, next.error, next.certainty, next.outcome = nil, nil, nil, nil
        effects[1] = effect
    elseif event.type == "resume" and state.pending then
        if state.certainty == "not_started" then
            -- A definitive refusal needs changed input, not repeated delivery.
        elseif repeatable(state.pending) then
            next.mode = "waiting"
            effects[1] = state.pending
        elseif state.certainty ~= "not_started" then
            unknown(next)
        end
    elseif state.mode == "waiting" and state.pending and event.id == state.pending.id then
        if event.type == "completed" then
            next.mode, next.phase, next.pending = "active", state.pending.next or state.phase, nil
            next.last = {kind=state.pending.kind, value=event.value}
            next.reason, next.error, next.certainty, next.outcome = nil, nil, nil, nil
        elseif event.type == "failed" then
            next.error, next.certainty = event.error, event.certainty
            next.reason = event.reason or event.error
            if event.certainty == "not_started" then
                if state.pending.refused then
                    next.mode, next.phase, next.pending = "active", state.pending.refused, nil
                    next.last = {kind=state.pending.kind, error=event.error}
                else next.mode = "parked" end
            elseif repeatable(state.pending) then
                -- Only delivery is uncertain. Resume sends the exact same effect.
                next.mode = "waiting"
            else
                unknown(next)
            end
        end
    end
    -- Responses from an old effect, including one already parked, change nothing.
    return next, effects
end

return M
