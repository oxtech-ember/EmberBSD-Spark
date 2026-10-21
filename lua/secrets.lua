-- Recognize structured credentials by their issuer prefixes.
-- This is answer redaction, not permission policy or arbitrary word filtering.
local M = {mark="[SECRET_HIDDEN]"}
local json,Sequence=require("json"),require("sequence")
local patterns = {
    {"%f[%w_]sk%-([A-Za-z0-9_-]+)",16},
    {"%f[%w_][sr]k_live_([A-Za-z0-9]+)",16},
    {"%f[%w_][sr]k_test_([A-Za-z0-9]+)",16},
    {"%f[%w_]gh[pousr]_([A-Za-z0-9]+)",20},
    {"%f[%w_]github_pat_([A-Za-z0-9_]+)",20},
    {"%f[%w_]glpat%-([A-Za-z0-9_-]+)",16},
    {"%f[%w_]AKIA([0-9A-Z]+)%f[^%w_]",16,16},
    {"%f[%w_]xox[baprs]%-([A-Za-z0-9-]+)",10},
    {"%f[%w_][Bb][Ee][Aa][Rr][Ee][Rr]%s+([A-Za-z0-9._~+/-]+)",25},
}
function M.text(text)
    local hidden = 0
    for _, ending in ipairs({"", " BLOCK"}) do
        local head = "%-%-%-%-%-BEGIN [A-Z ]*PRIVATE KEY" .. ending .. "%-%-%-%-%-"
        local at = 1
        while true do
            local first, last = text:find(head, at)
            if not first then break end
            local _, finish = text:find("%-%-%-%-%-END [A-Z ]*PRIVATE KEY[ A-Z]*%-%-%-%-%-", last+1)
            text = text:sub(1,first-1) .. M.mark .. (finish and text:sub(finish+1) or "")
            hidden, at = hidden+1, first+#M.mark
        end
    end
    for _, rule in ipairs(patterns) do
        local at = 1
        while true do
            local first,last,tail = text:find(rule[1],at)
            if not first then break end
            if #tail >= rule[2] and (not rule[3] or #tail == rule[3]) then
                text = text:sub(1,first-1) .. M.mark .. text:sub(last+1)
                hidden, at = hidden+1, first+#M.mark
            else at=last+1 end
        end
    end
    return text, hidden
end
function M.value(value)
    if type(value) == "string" then return M.text(value) end
    if type(value) ~= "table" or value==json.null then return value, 0 end
    local result,count=Sequence.empty_like(value),0
    if not Sequence.is(value) then
        -- Keep JSON shape, never copy a proxy's metamethods without its store.
        local kind=(getmetatable(value) or {}).__jsontype
        if kind then setmetatable(result,{__jsontype=kind}) end
    end
    for key,item in pairs(value) do
        local clean, n = M.value(item)
        result[key],count=clean,count+n
    end
    return result,count
end
return M
