-- Composition root for the small candidate. Adapters can be replaced without
-- teaching the attempt machine any tool, protocol or installation paths.
local json = require("json")
local fs = require("asenta.fs")
local Client = require("client")
local Model = require("model")
local MCP = require("mcp")
local Native = require("native")
local Worktree = require("worktree")
local Registry = require("registry")
local Authority = require("authority")
local Knowledge = require("knowledge")
local ServerTools = require("server_tools")
local Context = require("context")
local Runner = require("runner")
local Provenance = require("provenance")
local Workshop = require("workshop")
local Installation = require("installation")
local Mutators = require("mutators")
local Sequence = require("sequence")
local App = {}
App.__index = App
local function read(path)
    local file=assert(io.open(path,"rb")); local text=assert(file:read("*a"));file:close();return text
end
local function joined(base,name) return name:sub(1,1)=="/" and name or base .. "/" .. name end
local function nonempty(value) return type(value)=="string" and value~="" end

function App.new(config,options)
    options=options or {}
    config.limits=config.limits or {}
    local client=Client.new(config)
    local identity=client:request("GET","/api/v1/me")
    local actor=identity.user.userId
    local location=options.stateRoot or config.stateRoot or ((config.limits.workRoot or "/tmp/asenta-agent") .. ".lua")
    local namespace=fs.sha256(config.server.baseUrl .. "\n" .. ((identity.organization or {}).orgId or "") .. "\n" .. actor)
    local stateRoot=location .. "/" .. namespace
    local root=assert(fs.root(stateRoot,true))
    local connections={}
    local mcpRoot=options.mcpRoot or os.getenv("OXTORG_MCP")
    if not mcpRoot or mcpRoot=="" then mcpRoot=location .. "/mcp" end
    local specs,passports=Installation.rig(config,client,options)
    for _,spec in ipairs(specs) do
        local adapter=spec.module and Native or MCP
        local connection=adapter.connect(spec,{programDir=options.programDir,configDir=options.configDir,
            mcpRoot=mcpRoot,toolOutput=config.limits.toolOutput,
            timeoutMs=options.mcpTimeoutMs,caFile=(config.transport or {}).caFile,declarationRoot=root,root=root})
        connections[#connections+1]=connection
        local report=connection:report()
        if not report.connected and options.log then options.log(report.alias .. ": " .. tostring(report.reason)) end
    end
    config.worktreeRoot=options.worktreeRoot or config.worktreeRoot or location .. "/worktree"
    local manager=Worktree.new(config,client,identity)
    local workshop=Workshop.new(config,client,{stateRoot=stateRoot,context=options.context,log=options.log})
    return setmetatable({config=config,options=options,client=client,identity=identity,
        actor=actor,root=root,manager=manager,connections=connections,workshop=workshop,passports=passports},App)
end

function App:run(taskId)
    local client=self.client:for_task(taskId)
    local task=client:lease(taskId)
    assert(task.assigneeId==self.actor,"task belongs to another executor")
    local history=client:history(self.root)
    local stateName=fs.sha256(taskId)
    local saved,info=nil,self.root:stat(stateName .. ".json")
    if info then
        saved=json.decode(assert(self.root:read(stateName .. ".json",info.size)))
        if saved.sequenceSchema==1 then saved=Sequence.unpack(self.root,saved) end
    end
    if saved and saved.mode=="done" then assert(self.root:remove(stateName .. ".json"));saved=nil end
    local historyChanged=false
    if saved and saved.data.client then
        for _,event in ipairs(history) do
            if (event.cursor or 0)>(saved.data.client.readUpTo or 0) and event.level~="trace" and event.actorId~=self.actor then
                historyChanged=true;break
            end
        end
    end
    local view=self.manager:enter(taskId,task.ownerId,saved and saved.data.revision)
    local layers=(self.client:request("GET","/api/v1/me/role")).role or {}
    local memory=self.config.model.memory
    if layers.memory=="on" then memory=true elseif layers.memory=="off" then memory=false end
    local config={};for k,v in pairs(self.config) do config[k]=v end
    config.model={};for k,v in pairs(self.config.model) do config.model[k]=v end
    config.model.memory=memory
    local facts=""
    if memory then
        local values=client:request("GET","/api/v1/facts?subjectId=" .. Client.escape(task.ownerId)).facts or {}
        for _,fact in ipairs(values) do
            if fact.state=="active" then facts=facts .. "\n" .. fact.scope .. "/" .. fact.key .. ": " .. fact.text end
        end
    end
    local role=self.config.roleFile and read(joined(self.options.configDir or ".",self.config.roleFile)) or ""
    for _,layer in ipairs({layers.overlay or "",view and view.role or layers.agentLayer or ""}) do
        if layer~="" then role=role .. "\n\n" .. layer end
    end
    if saved then role=saved.data.role end
    local registry=Registry.new{toolOutput=self.config.limits.toolOutput,root=self.root}
    for _,connection in ipairs(self.connections) do
        for _,tool in ipairs(connection:tools()) do registry:add(tool) end
    end
    local model=Model.new(self.config,client)
    local current={origin="agent",author={alias=self.config.model.alias}}
    local function provenance() return current end
    if view then
        for _,tool in ipairs(Knowledge.tools(view,{client=client,config=self.config,task=task})) do registry:add(tool) end
    end
    for _,tool in ipairs(ServerTools.tools(client,task,{config=config,worktree=view,
        context=provenance,compacts=nonempty(self.config.model.compactor)})) do registry:add(tool) end
    for _,tool in ipairs(self.config.luaTools or {}) do
        local descriptor={}
        for k,v in pairs(tool) do descriptor[k]=v end
        descriptor.class=descriptor.class or "write_local"
        descriptor.invoke=assert(loadfile(joined(self.options.configDir or ".",descriptor.file),"t"))()
        registry:add(descriptor)
    end
    -- Installation-owned modules extend composition through ordinary require.
    for _,name in ipairs(self.config.modules or {}) do
        require(name).install{registry=registry,client=client,task=task,worktree=view,config=self.config,context=provenance}
    end
    local notebook=view and view.index or ""
    local skills=Knowledge.skills(view,{client=client,task=task})
    if saved and saved.data.selectedSkills then skills.selected=saved.data.selectedSkills end
    if not Sequence.is(skills.selected) then
        local selected=Sequence.new(self.root)
        for i,skill in ipairs(skills.selected) do selected[i]=skill end
        skills.selected=selected
    end
    local runnable=Sequence.new(self.root)
    for _,skill in ipairs(skills.catalogue) do
        local supported=true
        for _,tool in ipairs(skill.tools or {}) do
            if not self.workshop.enabled or tool.environment~="lua" then supported=false end
        end
        if supported then runnable[#runnable+1]=skill else
            for _,selected in ipairs(skills.selected) do assert(selected.name~=skill.name,"selected skill needs an unavailable runtime: " .. skill.name) end
        end
    end
    skills.catalogue=runnable
    current.skills=skills.selected
    for _,tool in ipairs(self.workshop:tools(task,view,provenance)) do registry:add(tool) end
    local wanted=self.config.limits.tools
    local function keepBuiltins()
    if wanted and #wanted>0 then
        local keep={my_failures=true,teach_myself=true,set_my_ceiling=true}
        for _,name in ipairs(wanted) do keep[name]=true end
        for name,tool in pairs(registry.byNative) do
            if tool.group=="oxtorg-native" and not keep[name] then
                registry.byNative[name],registry.byModel[tool.modelName]=nil,nil
            end
        end
    end
    end
    keepBuiltins()
    local function refreshShelf()
        for name,old in pairs(registry.byNative) do
            if old.group=="workshop" or name=="build_tool" then registry.byNative[name],registry.byModel[old.modelName]=nil,nil end
        end
        for _,added in ipairs(self.workshop:tools(task,view,provenance)) do registry:add(added) end
        keepBuiltins()
    end
    local accepted={}
    for _,name in ipairs(self.config.mutators or {}) do accepted[#accepted+1]=require(name) end
    local mutators=Mutators.new(accepted,{context=provenance,messageText=function(item)
        if item.type=="function_call" then return "assistant",item.arguments or "{}" end
        if item.type=="function_call_output" then return "tool",item.output or "" end
        if type(item.content)=="string" then return item.role,item.content end
        local text={};for _,part in ipairs(item.content or {}) do if part.text then text[#text+1]=part.text end end
        return item.role or "assistant",table.concat(text,"\n")
    end,withText=function(item,text)
        if item.type=="function_call" then item.arguments=text
        elseif item.type=="function_call_output" then item.output=text
        elseif type(item.content)=="string" then item.content=text
        else item.content=json.array({{type=item.role=="assistant" and "output_text" or "input_text",text=text}}) end
        return item
    end})
    for _,tool in ipairs(mutators:tools(provenance)) do registry:add(tool) end
    local contextOptions=Sequence.fields(self.root,
        {root=self.root,role=role,notebook=notebook,facts=facts,skills=skills.text,actorId=self.actor,registry=registry},
        {"role","notebook","facts","skills"})
    local prepared=Context.prepare(task,history,contextOptions)
    local provenanceOptions=Sequence.clone(contextOptions)
    provenanceOptions.task,provenanceOptions.history,provenanceOptions.foreign=task,history,prepared.foreign
    local chain=Provenance.new(provenanceOptions,saved and saved.data.provenance)
    local authority=Authority.new(client,task,history,registry,{actorId=self.actor})
    local turns=self.config.limits.maxTurns or 8
    if layers.maxTurns and layers.maxTurns>0 then turns=layers.maxTurns end
    for _,ceiling in ipairs(layers.ceilings or {}) do
        if ceiling.variable=="turns" and ceiling.value>0 then turns=ceiling.value end
    end
    local engine=task.kind=="run" and require("rows").run or Runner.run
    local engineContext=Sequence.clone(contextOptions)
    local run={config=config,task=task,client=client,model=model,registry=registry,
        authority=authority,root=self.root,stateName=stateName,history=history,input=prepared.input,context=prepared,
        controls=true,controlContext={catalogue=skills.catalogue,pinned=view~=nil},
        keepWhole=true,
        onSkills=function(plan)
            skills.selected,current.skills=plan.skills,plan.skills
            refreshShelf()
        end,
        contextOptions=contextOptions,actorId=self.actor,historyChanged=historyChanged,
        foreign=prepared.foreign,roleVersion=layers.version,maxTurns=turns,
        workspaceId=view and view.snapshot.workspaceId,worktreeId=view and view.snapshot.worktreeId,
        revision=view and view.revision,beforeTurn=function(input,number)
            return mutators:before_turn(number,input)
        end,beforeCall=function(call,tool,data)
            local changed,report=mutators:before_tool(call)
            data.argsChangedBy=report.changedBy
            if report.refusal then return false,report.refusal end
            call.args=changed.args
            if #report.changedBy>0 then call.arguments=json.encode(changed.args) end
            return chain:before(call,tool,{stepId=data.step,reply=data.reply,foreign=data.foreign})
        end,provenanceState=function() return chain.state end,
        transformResult=function(call,result)
            local output,changed=mutators:after_tool(call,{text=result.whole,isError=result.error})
            result.whole,result.error,result.outputChangedBy=output.text,output.isError,changed
            if #changed>0 then result.output=Registry.head(output.text,registry.toolOutput) end
        end,
        afterTool=function(call,result,data)
            chain:heard(call,result)
            local tool=registry:find(call.name)
            if tool and tool.growsShelf then
                refreshShelf()
                result.definitions=registry:definitions()
            end
            return chain.state
        end,beforeTool=function(_,data)
            local reply=data.reply or {}
            current=chain:context(reply)
            current.skills=skills.selected
            if view then view:set_provenance(current.author,current.origin) end
        end}
    for key,value in pairs(run) do engineContext[key]=value end
    -- Drop preparation-only strings before the paid loop. Lazy fields in the
    -- context and registry reload a single value only when it is used.
    role,notebook,facts,skills.text,layers,saved=nil,nil,nil,nil,nil,nil
    if view then view.role,view.index=nil,nil end
    local result=engine(engineContext)
    mutators:close()
    return result
end
App.run_rows=App.run

function App:close()
    for _,connection in ipairs(self.connections) do connection:close() end
    self.workshop:close();self.manager:close();self.root:close()
end
function App:status(taskId)
    local name=fs.sha256(taskId) .. ".json"
    local info=self.root:stat(name)
    if not info then return end
    local state=json.decode(assert(self.root:read(name,info.size)))
    if state.sequenceSchema==1 then state=Sequence.unpack(self.root,state) end
    local pending=state.pending or {}
    return {mode=state.mode,phase=state.phase,outcome=state.outcome,reason=state.reason,certainty=state.certainty,
        pendingKind=pending.kind,replay=pending.replay,version=(state.data.client or {}).version,
        attemptId=state.attemptId}
end
return App
