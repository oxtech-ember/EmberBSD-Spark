-- The SMALL queue is serial. The application owns leases and attempt recovery;
-- the scheduler owns polling, inventory delivery and the gap between attempts.
local json = require("json")
local fs = require("asenta.fs")
local core = require("asenta.core")
local secrets = require("secrets")
local Scheduler = {}
Scheduler.__index = Scheduler
local ready = {working=true,submitted=true}
local repeatOutcome = {superseded=true,retry=true,deferred=true}
local function object(value) return type(value) == "table" and value ~= json.null end
local function canonical(value)
    if not object(value) then return json.encode(value) end
    local parts = {}
    if #value > 0 or (getmetatable(value) or {}).__jsontype == "array" then
        for _, item in ipairs(value) do parts[#parts+1]=canonical(item) end
        return "[" .. table.concat(parts,",") .. "]"
    end
    local keys = {}; for key in pairs(value) do keys[#keys+1]=key end; table.sort(keys)
    for _, key in ipairs(keys) do parts[#parts+1]=json.encode(key) .. ":" .. canonical(value[key]) end
    return "{" .. table.concat(parts,",") .. "}"
end

-- The tasks endpoint is {tasks:[Task,...]}. Retain one wire task at a time,
-- keeping only assigned runnable tasks after decoding. A task never starts
-- inside the HTTP consumer or before the entire response has been validated.
local function task_stream(actor)
    local parser = {buffer="",mode="header",at=1,depth=0,quoted=false,escaped=false,tasks={}}
    function parser:consume(chunk)
        self.buffer = self.buffer .. chunk
        while true do
            if self.mode == "header" then
                local at = self.buffer:match('^%s*{%s*"tasks"%s*:%s*()')
                if not at or at > #self.buffer then return end
                local char = self.buffer:sub(at,at)
                if char == "[" then self.buffer=self.buffer:sub(at+1); self.mode="item"
                elseif self.buffer:sub(at,at+3) == "null" then self.buffer=self.buffer:sub(at+4); self.mode="end"
                elseif char == "n" and #self.buffer-at < 3 then return
                else error("invalid streamed task list") end
            elseif self.mode == "item" or self.mode == "separator" then
                self.buffer = self.buffer:gsub("^%s+","")
                if self.buffer == "" then return end
                local char = self.buffer:sub(1,1)
                if char == "]" then self.buffer=self.buffer:sub(2); self.mode="end"
                elseif self.mode == "separator" then
                    assert(char == ",","invalid task list separator")
                    self.buffer=self.buffer:sub(2); self.mode="next-item"
                else
                    assert(char == "{","task list entry must be an object")
                    self.mode,self.at,self.depth,self.quoted,self.escaped="object",1,0,false,false
                end
            elseif self.mode == "next-item" then
                self.buffer = self.buffer:gsub("^%s+","")
                if self.buffer == "" then return end
                assert(self.buffer:sub(1,1) == "{","task list entry must be an object")
                self.mode,self.at,self.depth,self.quoted,self.escaped="object",1,0,false,false
            elseif self.mode == "object" then
                while self.at <= #self.buffer do
                    local char = self.buffer:sub(self.at,self.at)
                    if self.quoted then
                        if self.escaped then self.escaped=false
                        elseif char == "\\" then self.escaped=true
                        elseif char == '"' then self.quoted=false end
                    elseif char == '"' then self.quoted=true
                    elseif char == "{" or char == "[" then self.depth=self.depth+1
                    elseif char == "}" or char == "]" then self.depth=self.depth-1 end
                    self.at = self.at + 1
                    if self.depth == 0 then
                        local task = json.decode(self.buffer:sub(1,self.at-1))
                        if task.assigneeId == actor and ready[task.state] then
                            assert(type(task.taskId) == "string" and task.version ~= nil,"task identity or version is missing")
                            self.tasks[#self.tasks+1]=task
                        end
                        self.buffer,self.mode=self.buffer:sub(self.at),"separator"
                        break
                    end
                end
                if self.mode == "object" then return end
            elseif self.mode == "end" then
                self.buffer = self.buffer:gsub("^%s+","")
                if self.buffer == "" then return end
                assert(self.buffer:sub(1,1) == "}","invalid task list closing object")
                self.buffer,self.mode=self.buffer:sub(2),"done"
            else
                assert(not self.buffer:find("%S"),"trailing task list data")
                self.buffer=""; return
            end
        end
    end
    function parser:finish()
        assert(self.mode == "done","incomplete streamed task list")
        return self.tasks
    end
    return parser
end

function Scheduler.capabilities(build)
    local reports = json.array({{environment="native",available=true,version=build or require("version")},
        {environment="mcp",available=true},{environment="lua",available=true,version=_VERSION}})
    for _, name in ipairs({"shell","node","mutator","git","pdf","embeddings","browser","docx","xlsx","kits"}) do
        reports[#reports+1]={environment=name,available=false,reason="build_unsupported"}
    end
    return reports
end
function Scheduler.new(app, options)
    options = options or {}
    assert(type(app.actor) == "string" and app.actor ~= "","scheduler needs the authenticated executor identity")
    local root = assert(app.root,"scheduler needs the application's state root")
    local lock = assert(root:lock("scheduler.lock"))
    local ok, state = pcall(function()
        local info, err = root:stat("scheduler.json"); assert(not err,err)
        return info and json.decode(assert(root:read("scheduler.json",info.size))) or {tasks={}}
    end)
    if not ok then lock:close(); error(state,0) end
    return setmetatable({app=app,options=options,root=root,lock=lock,state=state,refused={},
        clock=options.clock or core.monotonic_ms,sleep=options.sleep or core.sleep},Scheduler)
end
function Scheduler:_save() assert(self.root:write("scheduler.json",canonical(self.state))) end
function Scheduler:_log(value)
    if self.options.log then self.options.log(secrets.text(tostring(value))) end
end
function Scheduler:_stopped()
    return self.stopped or self.options.canceled and self.options.canceled()
end
function Scheduler:_status(taskId)
    return self.app.status and self.app:status(taskId) or nil
end
function Scheduler:_queue()
    local stream = task_stream(self.app.actor)
    -- Match oxtorg.Client.readStream's endpoint bound, with an explicit
    -- installation response limit taking precedence over that endpoint.
    local configured = ((self.app.config or {}).transport or {}).maxBytes
    local limit = configured and configured > 0 and math.min(configured,32*1024*1024) or 32*1024*1024
    self.app.client:request("GET","/api/v1/tasks?state=submitted&state=working",nil,false,
        {maxBytes=limit,consume=function(chunk) stream:consume(chunk) end})
    return stream:finish()
end
function Scheduler:_inventory()
    if self.options.report then return self.options.report(self.app) end
    local servers, named, available = json.array(), {}, json.array()
    for _, connection in ipairs(self.app.connections or {}) do
        local report=connection:report(); servers[#servers+1]=report; named[report.alias]=true
    end
    for _, passport in ipairs(self.app.passports or {}) do
        if not named[passport.alias] then
            local item={alias=passport.alias,name=passport.name,version=passport.version,tools=json.array(),env=json.array()}
            for _, tool in ipairs(passport.tools or {}) do
                item.tools[#item.tools+1]={name=tool.name,title=tool.title,class=tool.class}
            end
            -- Inventory carries the passport's declarations, never variable
            -- values or installation paths (the same projection as Go).
            for _, env in ipairs(passport.env or {}) do
                item.env[#item.env+1]={name=env.name,required=env.required or false,purpose=env.purpose,file=env.file}
            end
            available[#available+1]=item
        end
    end
    return {servers=servers,environments=self.options.environments or Scheduler.capabilities(self.options.build),
        available=self.options.available or available,stopped=self.app.stopReports and self.app:stopReports() or json.array(),researchSeats=1}
end
function Scheduler:_deliver()
    local ok, why = pcall(function()
        local report = self:_inventory()
        local mark = fs.sha256(canonical(report))
        if mark == self.delivered or self.retryAt and self.clock() < self.retryAt then return end
        local sent, err = pcall(self.app.client.request,self.app.client,"PUT","/api/v1/me/tools",report,false)
        if not sent then self.retryAt=self.clock()+60000; error(err,0) end
        self.delivered,self.retryAt=mark,nil
    end)
    if not ok then self:_log("Tool inventory: " .. tostring(why)) end
end
function Scheduler:_remember(task, result, status)
    result, status = result or {}, status or {}
    local outcome = result.outcome or status.outcome
    local resume = result.resume == true or repeatOutcome[outcome]
    if result.resume == nil and status.mode ~= "done" and status.certainty ~= "not_started" then
        resume = status.mode == "active" or status.replay == "safe" or status.replay == "delivery"
    end
    self.state.tasks[task.taskId]={version=result.version or status.version or task.version,
        mode=resume and "retry" or "waiting",outcome=outcome,reason=result.reason or status.reason,
        attemptId=status.attemptId}
    self:_save()
end
function Scheduler:_eligible(task, status)
    if self.refused[task.taskId] == task.version then return false end
    local record = self.state.tasks[task.taskId]
    -- A completed durable attempt wins over a stale scheduler "running" mark
    -- left by a crash after completion and before the scheduler's checkpoint.
    if status and status.mode == "done" and not repeatOutcome[status.outcome] then
        if status.version == task.version then
            if not record or record.mode ~= "waiting" or record.version ~= task.version then self:_remember(task,status,status) end
            return false
        end
    end
    if not record or record.mode == "running" or record.mode == "retry" then return true end
    if status and repeatOutcome[status.outcome] then return true end
    return record.version ~= task.version or status and status.attemptId ~= record.attemptId
end
function Scheduler:_task(task, summary)
    local status = self:_status(task.taskId)
    if not self:_eligible(task,status) then summary.held=summary.held+1; return end
    local run = self.app.run
    if task.kind == "run" then run=self.app.run_rows end
    if not run then
        self:_remember(task,{outcome="unsupported_task_kind",version=task.version,resume=false},status)
        self:_log("Task " .. task.taskId .. ": unsupported_task_kind"); summary.held=summary.held+1
        return
    end
    self.state.tasks[task.taskId]={version=task.version,mode="running",attemptId=status and status.attemptId}
    self:_save()
    local ok, result = pcall(run,self.app,task.taskId)
    summary.ran=summary.ran+1
    if ok then
        self:_remember(task,result,self:_status(task.taskId))
        self:_log("Task " .. task.taskId .. ": " .. tostring(result.outcome) ..
            (result.reason and " (" .. (object(result.reason) and json.encode(result.reason) or tostring(result.reason)) .. ")" or ""))
        return
    end
    local reason = object(result) and result.reason
    local code = object(result) and result.status
    if reason == "asleep" or reason == "lease_taken" or reason == "task_canceled" or code == 403 then
        -- Wake and lease expiry need not change task.version. A permission
        -- refusal is memoized only for this process, matching the Go runner.
        self.state.tasks[task.taskId]=nil
        if code == 403 then self.refused[task.taskId]=task.version end
        self:_save()
    else
        status = self:_status(task.taskId)
        if status then self:_remember(task,{reason=reason},status)
        else
            -- App creates a durable attempt before any paid call. A
            -- connection/preparation failure before it may retry.
            self.state.tasks[task.taskId]=nil; self:_save()
        end
    end
    if reason ~= "asleep" and reason ~= "lease_taken" then error(result,0) end
end
function Scheduler:sweep()
    assert(self.lock,"scheduler is closed")
    if self:_stopped() then return {ran=0,held=0,failed=0} end
    if self.app.manager then
        local called, ok, failures = pcall(self.app.manager.sync,self.app.manager)
        if not called or not ok then self:_log("Worktree outbox: " .. tostring(called and failures[1] or ok)) end
    end
    self:_deliver()
    local queue, present = self:_queue(), {}
    local summary = {ran=0,held=0,failed=0}
    for _, task in ipairs(queue) do
        present[task.taskId]=true
        if self:_stopped() then break end
        local ok, why = pcall(self._task,self,task,summary)
        if not ok then
            summary.failed=summary.failed+1
            self:_log("Task " .. task.taskId .. ": " .. tostring(why))
        end
    end
    local changed = false
    for taskId in pairs(self.state.tasks) do
        if not present[taskId] and not self:_stopped() then self.state.tasks[taskId]=nil; self.refused[taskId]=nil; changed=true end
    end
    for taskId in pairs(self.refused) do if not present[taskId] and not self:_stopped() then self.refused[taskId]=nil end end
    if changed then self:_save() end
    self:_deliver()
    return summary
end
function Scheduler:run(once)
    local last
    while not self:_stopped() do
        local ok, result = pcall(self.sweep,self)
        if ok then last=result
        elseif once then error(result,0)
        else self:_log("Task queue: " .. tostring(result)) end
        if once or self:_stopped() then break end
        local poll = ((self.app.config or {}).server or {}).pollMs or 0
        -- Attempts have released their files and response tables. Do not keep
        -- dead objects resident while the queue waits for more work.
        collectgarbage("collect")
        self.sleep(poll > 0 and poll or 5000)
    end
    return last
end
function Scheduler:stop() self.stopped=true end
function Scheduler:close()
    if self.lock then assert(self.lock:close()); self.lock=nil end
end
return Scheduler
