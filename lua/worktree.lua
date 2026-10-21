local json = require("json")
local fs = require("asenta.fs")
local core = require("asenta.core")
local Codec = require("worktree_codec")
local Stream = require("snapshot_stream")
local Sequence = require("sequence")
local Worktree, View = {}, {}
Worktree.__index, View.__index = Worktree, View

-- Source bounds are shared with worktree/validate.go and notebook/notebook.go.
-- JSON escaping can expand each source byte sixfold. Contents are streamed
-- to immutable files; manifests and draft views contain only their hashes.
local MAX_FILES, MAX_FILE, MAX_TOTAL = 1000, 1048576, 16777216
local MAX_JSON = MAX_TOTAL * 6 + 65536
local MARKER = "<!-- asenta-notebook-layout:1 -->"
local API = "/api/v1/me/worktree"
local terminal = {published=true, conflict=true, refused=true, unapplied=true, rejected=true}
local excluded = {data=true, ["machine.json"]=true, runtime=true, ["runtime.json"]=true,
    credentials=true, ["credentials.json"]=true, secrets=true, ["secrets.json"]=true,
    ["token.json"]=true, ["tokens.json"]=true}

local function trim(value) return (value or ""):match("^%s*(.-)%s*$") end
local function escape(value) return value:gsub("[^%w%-._~]", function(c) return ("%%%02X"):format(c:byte()) end) end
local function copy(value)
    if type(value) ~= "table" or value == json.null then return value end
    local result = setmetatable({}, getmetatable(value))
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end
local function keys(value)
    local result = {}
    for key in pairs(value) do result[#result+1] = key end
    table.sort(result)
    return result
end
local function canonical(value)
    if type(value) ~= "table" or value == json.null then return json.encode(value) end
    local entries = {}
    if (getmetatable(value) or {}).__jsontype == "array" or value[1] ~= nil then
        for _, child in ipairs(value) do entries[#entries+1] = canonical(child) end
        return "[" .. table.concat(entries, ",") .. "]"
    end
    for _, key in ipairs(keys(value)) do entries[#entries+1] = json.encode(key) .. ":" .. canonical(value[key]) end
    return "{" .. table.concat(entries, ",") .. "}"
end
local function lines(text)
    if text == "" then return 0 end
    local _, count = text:gsub("\n", "")
    return count + (text:sub(-1) == "\n" and 0 or 1)
end
local function source_path(name)
    assert(type(name) == "string" and #name > 0 and #name <= 512 and utf8.len(name)
        and not name:find("[\\:]"), "source path must be a canonical relative path")
    local parts = {}
    for part in (name .. "/"):gmatch("(.-)/") do
        assert(#part <= 128 and part:match("^[A-Za-z0-9_][A-Za-z0-9_.-]*$")
            and part:sub(-1) ~= ".", "unsafe source path: " .. name)
        local lower = part:lower()
        local stem = lower:match("^[^.]+")
        assert(stem ~= "con" and stem ~= "prn" and stem ~= "aux" and stem ~= "nul"
            and not stem:match("^com[1-9]$") and not stem:match("^lpt[1-9]$")
            and not excluded[lower], "reserved source path: " .. name)
        parts[#parts+1] = part
    end
    assert(#parts >= 2, "source path needs an allowed root")
    local root = parts[1]
    assert((root == "notebook" and name:sub(-3) == ".md") or
        (root == "role" and name == "role/agent.md") or
        ((root == "tools" or root == "skills") and #parts >= 3) or
        root == "checks" or root == "dependencies", "unsupported source path: " .. name)
end
local function text_bounds(name, text)
    source_path(name)
    assert(type(text) == "string" and #text <= MAX_FILE and utf8.len(text)
        and not text:find("\0", 1, true), "source must be bounded UTF-8 text without NUL: " .. name)
    if name:sub(1,9) == "notebook/" then
        assert(lines(text) <= 300, "note exceeds 300 lines: " .. name)
        assert(name ~= "notebook/index.md" or utf8.len(text) <= 12000, "notebook index exceeds 12000 characters")
    end
end
local function bundle(manager, files)
    local count, total = 0, 0
    for name, ref in pairs(files) do
        source_path(name)
        count, total = count + 1, total + manager:_size(ref)
        local parent = name:match("^(.*)/[^/]+$")
        while parent do
            assert(files[parent] == nil, "source is also a directory: " .. parent)
            parent = parent:match("^(.*)/[^/]+$")
        end
    end
    assert(count <= MAX_FILES and total <= MAX_TOTAL, "worktree source quota exceeded")
    return count
end
local function file_map(snapshot)
    local result = {}
    assert(type(snapshot.files) == "table", "snapshot has no files")
    for _, file in ipairs(snapshot.files) do
        assert(type(file.name) == "string" and type(file.blob) == "string", "snapshot file needs name and blob")
        assert(result[file.name] == nil, "duplicate source in snapshot")
        result[file.name] = file.blob
    end
    return result
end
local function changed(base, current, paths)
    local selected = {}
    if paths then
        for _, name in ipairs(paths) do source_path(name); selected[name] = true end
    else
        for name in pairs(base) do selected[name] = true end
        for name in pairs(current) do selected[name] = true end
    end
    local changes = json.array()
    for _, name in ipairs(keys(selected)) do
        assert(base[name] ~= nil or current[name] ~= nil, "source is neither present nor a tracked deletion: " .. name)
        if base[name] ~= current[name] then
            local entry = {name=name}
            if current[name] == nil then entry.delete = true else entry.blob = current[name] end
            changes[#changes+1] = entry
        end
    end
    return changes
end
local function applied(base, changes)
    local result = copy(base)
    for _, change in ipairs(changes) do result[change.name] = not change.delete and change.blob or nil end
    return result
end
local function same_tree(a, b) return a.workspaceId == b.workspaceId and a.worktreeId == b.worktreeId end
local function status_of(err) return type(err) == "table" and err.status or nil end
local function digest(ref) return ref or fs.sha256("deleted") end
local function known(author) return type(author) == "table" and (trim(author.alias) ~= "" or trim(author.model) ~= "") end
local function author_list(previous, author)
    local result = copy(previous or json.array())
    for _, value in ipairs(result) do
        if (value.alias or "") == (author.alias or "") and (value.model or "") == (author.model or "") then return result end
    end
    result[#result+1] = copy(author)
    return result
end

function Worktree.new(config, client, identity)
    local workspace = assert(identity.organization.orgId or identity.organization.id, "identity has no organization")
    local actor = assert(identity.user.userId or identity.user.id, "identity has no user")
    local endpoint = assert(client.config.server.baseUrl or client.config.server.baseURL, "server endpoint is missing")
    local base = trim(os.getenv("OXTORG_WORKTREE"))
    if base == "" then base = trim(config.worktreeRoot) end
    return setmetatable({config=config, client=client, workspace=workspace, actor=actor, base=base,
        namespace=fs.sha256(endpoint .. "\n" .. workspace .. "\n" .. actor)}, Worktree)
end
function Worktree:_root()
    if not self.root then
        assert(self.base ~= "", "configure worktreeRoot or OXTORG_WORKTREE for the assigned worktree")
        -- Lua keeps its own runtime format alongside the Go cache. Published
        -- knowledge still comes from the same authenticated server revision.
        self.root = assert(fs.root(self.base .. "/" .. self.namespace .. "/lua", true))
    end
    return self.root
end
function Worktree:_load(path)
    local root = self:_root()
    local info, err = root:stat(path)
    assert(not err, err)
    if not info then return nil end
    local value = json.decode(assert(root:read(path, MAX_JSON * 5)))
    if type(value) == "table" and value.format == "worktree-references-v1" then
        value = Sequence.unpack(root,value.value)
    else value = Codec.unpack(value) end
    -- Upgrade former inline records once. New installations never decode the
    -- entire corpus, and all subsequent reads load references only.
    if type(value) == "table" then
        local migrated = false
        if value.digest then
            assert(fs.sha256(canonical(value.snapshot)) == value.digest, "cached snapshot digest does not match its bytes")
        end
        for _, field in ipairs({"snapshot", "commitBase"}) do
            local snapshot = value[field]
            if snapshot and snapshot.files and snapshot.storage ~= "files-v1" then
                for _, file in ipairs(snapshot.files) do
                    file.blob, file.text = self:_put(file.name, file.text), nil
                end
                snapshot.storage, migrated = "files-v1", true
            end
        end
        if value.commitBase and value.storage ~= "files-v1" then
            for _, field in ipairs({"files", "observed", "checkpoint"}) do
                for name, body in pairs(value[field]) do value[field][name] = self:_put(name, body) end
            end
            value.storage, migrated = "files-v1", true
        end
        if migrated then
            if value.digest then value.digest = fs.sha256(canonical(value.snapshot)) end
            self:_save(path, value)
        end
    end
    return value
end
function Worktree:_save(path, value)
    assert(self:_root():write(path, canonical({format="worktree-references-v1", value=Sequence.pack(value)})))
end
local function blob_path(ref)
    assert(type(ref) == "string" and #ref == 64 and ref:match("^[a-f0-9]+$"), "invalid source reference")
    return "sources/" .. ref:sub(1,2) .. "/" .. ref
end
function Worktree:_put(name, text)
    text_bounds(name, text)
    local ref = fs.sha256("source\n" .. text)
    local path, root = blob_path(ref), self:_root()
    local info, err = root:stat(path)
    assert(not err, err)
    if not info then assert(root:write(path, text)) end
    return ref
end
function Worktree:_read(ref)
    if not ref then return nil end
    local text = assert(self:_root():read(blob_path(ref), MAX_FILE))
    assert(fs.sha256("source\n" .. text) == ref, "source digest does not match its bytes")
    return text
end
function Worktree:_size(ref)
    local info = assert(self:_root():stat(blob_path(ref)), "source file is missing")
    assert(info.kind == "file" and info.size <= MAX_FILE, "invalid source file")
    return info.size
end
function Worktree:_references(changes)
    local result = json.array()
    for _, change in ipairs(changes) do
        result[#result+1] = {name=change.name, delete=change.delete,
            blob=not change.delete and self:_put(change.name, change.text) or nil}
    end
    return result
end
function Worktree:_contents(changes)
    local result = Sequence.new(self:_root())
    for _, change in ipairs(changes) do
        result[#result+1] = {name=change.name, delete=change.delete,
            text=not change.delete and self:_read(change.blob) or nil}
    end
    return result
end
function Worktree:_entries(path)
    local root = self:_root()
    local info, err = root:stat(path)
    assert(not err, err)
    if not info then return {} end
    local entries = assert(root:list(path))
    table.sort(entries, function(a,b) return a.name < b.name end)
    return entries
end
function Worktree:_request(method, path, value, options)
    return self.client:request(method, path, value, false, options or {maxBytes=MAX_JSON})
end
function Worktree:_binding(offline)
    local ok, binding, status = pcall(self._request, self, "GET", API, nil,
        {allowStatus={[404]=true}, maxBytes=MAX_JSON})
    self.bindingOnline = ok
    if ok and status == 404 then return nil end
    if not ok then
        if not offline or status_of(binding) then error(binding, 0) end
        binding = assert(self:_load("binding.json"), "no cached worktree binding")
    end
    assert(type(binding) == "table" and binding.workspaceId == self.workspace and
        type(binding.worktreeId) == "string" and binding.worktreeId ~= "" and
        type(binding.revision) == "string", "assigned worktree binding is incomplete or belongs to another organization")
    self:_save("binding.json", binding)
    return binding
end
function Worktree:_snapshot(binding, offline)
    local path = "trees/" .. fs.sha256(binding.workspaceId .. "/" .. binding.worktreeId) ..
        "/snapshots/" .. fs.sha256(binding.revision) .. ".json"
    local cache = self:_load(path)
    if cache then
        assert(same_tree(cache.snapshot, binding) and cache.snapshot.revision == binding.revision,
            "cached snapshot differs from the requested revision")
        return cache.snapshot, self.bindingOnline == true
    end
    local files, seen, total = json.array(), {}, 0
    local parser = Stream.new(function(file)
        assert(not seen[file.name], "duplicate source in snapshot")
        local ref = self:_put(file.name, file.text)
        total = total + #file.text
        assert(#files < MAX_FILES and total <= MAX_TOTAL, "worktree source quota exceeded")
        files[#files+1] = {name=file.name, blob=ref}
        seen[file.name] = true
    end)
    self:_request("GET", API .. "/snapshot?revision=" .. escape(binding.revision), nil,
        {maxBytes=MAX_JSON, consume=function(chunk) parser:feed(chunk) end})
    local snapshot = parser:finish()
    snapshot.files, snapshot.storage = files, "files-v1"
    assert(same_tree(snapshot, binding) and snapshot.revision == binding.revision,
        "snapshot differs from the requested worktree or revision")
    bundle(self, file_map(snapshot))
    self:_save(path, {snapshot=snapshot, digest=fs.sha256(canonical(snapshot))})
    return snapshot, true
end

function Worktree:_outbox()
    local result = {}
    for _, entry in ipairs(self:_entries("outbox")) do
        if entry.kind == "file" and entry.name:match("%.json$") then
            result[#result+1] = assert(self:_load("outbox/" .. entry.name))
        end
    end
    table.sort(result, function(a,b)
        if a.taskRoot ~= b.taskRoot then return a.taskRoot < b.taskRoot end
        return a.sequence < b.sequence
    end)
    return result
end
function Worktree:_acknowledge(queued, publication, where)
    if publication.state ~= "published" then return end
    where = where or queued.attempt
    local state = assert(self:_load(where), "publication draft is missing")
    if state.acknowledged[queued.proposal.id] then return end
    local binding = assert(self:_binding(false), "worktree assignment was removed")
    assert(same_tree(binding, queued.binding), "publication belongs to another worktree assignment")
    local snapshot = self:_snapshot(binding, false)
    state.observed = applied(state.observed, self:_references(queued.proposal.changes))
    state.commitBase, state.acknowledged[queued.proposal.id] = snapshot, true
    self:_save(where, state)
end
function Worktree:_send(queued)
    local binding = assert(self:_binding(false), "worktree assignment was removed")
    assert(same_tree(binding, queued.binding), "outbox belongs to another worktree assignment")
    local ok, result = pcall(self._request, self, "POST", API .. "/changes", queued.proposal)
    if not ok then
        local status = status_of(result)
        if status and status < 500 then
            self:_save("publications/" .. queued.proposal.id .. ".json",
                {id=queued.proposal.id, state=status == 409 and "conflict" or "refused"})
            self:_save("failures/" .. queued.proposal.id .. ".json",
                {status=status, reason=result.reason, message=result.message or tostring(result)})
        end
        error(result, 0)
    end
    assert(result.id == queued.proposal.id and type(result.state) == "string", "publication identity is invalid")
    self:_save("publications/" .. result.id .. ".json", result)
    self:_acknowledge(queued, result)
    return result
end
function Worktree:sync()
    local failures = {}
    for _, queued in ipairs(self:_outbox()) do
        local ok, err = pcall(function()
            local publication = self:_load("publications/" .. queued.proposal.id .. ".json")
            if not publication then self:_send(queued); return end
            if not terminal[publication.state] then
                publication = self:_request("GET", API .. "/changes/" .. escape(queued.proposal.id))
                assert(publication.id == queued.proposal.id, "publication identity is invalid")
                self:_save("publications/" .. publication.id .. ".json", publication)
            end
            self:_acknowledge(queued, publication)
        end)
        if not ok then failures[#failures+1] = err end
    end
    if #failures > 0 then return nil, failures end
    return true
end

local function view_for(manager, state, attempt, tree, taskRoot)
    local model = manager.config.model or {}
    local published = file_map(state.snapshot)
    return setmetatable({manager=manager, state=state, attempt=attempt, tree=tree, taskRoot=taskRoot,
        revision=state.snapshot.revision, snapshot=copy(state.snapshot), role=manager:_read(published["role/agent.md"]) or "",
        index=manager:_read(state.files["notebook/index.md"]) or "", author={alias=model.alias or "", model=model.name or ""}, origin="agent"}, View)
end
function Worktree:enter(taskId, ownerId, revision)
    assert(type(taskId) == "string" and taskId ~= "" and type(ownerId) == "string" and ownerId ~= "", "task and owner are required")
    assert(revision == nil or type(revision) == "string", "pinned revision must be a string")
    -- No local cache is needed when the authenticated server explicitly says
    -- the executor has no corporate assignment.
    if self.base ~= "" then self:sync() end
    local binding = self:_binding(true)
    if not binding then
        assert(revision == nil, "the pinned attempt's worktree assignment was removed")
        assert(self.assigned ~= true, "worktree assignment was removed; restart before another task")
        self.assigned = false
        return nil
    end
    assert(self.assigned ~= false, "worktree assignment was added; restart before another task")
    self.assigned = true
    local latestRevision = binding.revision
    -- Authenticate the current assignment before asking for an older pinned
    -- revision. A process restart is not an attempt boundary or a rebase.
    if revision ~= nil then binding = copy(binding); binding.revision = revision end
    local tree = "trees/" .. fs.sha256(binding.workspaceId .. "/" .. binding.worktreeId)
    local taskRoot = tree .. "/drafts/" .. fs.sha256(taskId .. "/" .. ownerId)
    local ownerPath = tree .. "/tasks/" .. fs.sha256(taskId) .. ".json"
    local owner = self:_load(ownerPath)
    assert(not owner or owner == ownerId, "worktree draft belongs to another task owner")
    self:_save(ownerPath, ownerId)
    local snapshot, fresh = self:_snapshot(binding, true)
    local published = file_map(snapshot)
    local files, provenance = copy(published), {}
    local pointer = self:_load(taskRoot .. "/draft.json")
    if pointer then
        local prior = assert(self:_load(pointer.attempt), "saved draft is missing")
        assert(prior.taskId == taskId and prior.ownerId == ownerId and same_tree(prior.snapshot, binding), "saved draft identity differs")
        bundle(self, prior.files)
        if revision ~= nil then
            assert(prior.snapshot.revision == revision, "saved attempt differs from the requested pinned revision")
            prior.snapshot = snapshot
            return view_for(self, prior, pointer.attempt, tree, taskRoot)
        end
        local conflicts, keep = json.array(), json.array()
        for _, change in ipairs(changed(prior.observed, prior.files)) do
            if prior.observed[change.name] ~= published[change.name] and
                (change.delete and published[change.name] ~= nil or not change.delete and change.blob ~= published[change.name]) then
                conflicts[#conflicts+1] = change.name
            else keep[#keep+1] = change end
        end
        if #conflicts > 0 then
            self:_save(taskRoot .. "/archives/" .. prior.id .. ".json", {attempt=pointer.attempt, conflicts=conflicts})
        end
        files = applied(published, keep)
        for _, change in ipairs(keep) do
            local mark = prior.provenance[change.name]
            if mark then
                mark = copy(mark)
                if mark.digest ~= digest(files[change.name]) then mark.origin = "external" end
                provenance[change.name] = mark
            end
        end
    end
    local state = {storage="files-v1", id=core.identifier(), taskId=taskId, ownerId=ownerId, snapshot=snapshot,
        files=files, observed=copy(published), commitBase=copy(snapshot), checkpoint=copy(published),
        provenance=provenance, acknowledged={}}
    if fresh and snapshot.revision == latestRevision then
        for _, queued in ipairs(self:_outbox()) do
            local publication = self:_load("publications/" .. queued.proposal.id .. ".json")
            if queued.taskRoot == taskRoot and publication and publication.state == "published" then
                state.acknowledged[queued.proposal.id] = true
            end
        end
    end
    local attempt = taskRoot .. "/attempts/" .. state.id .. ".json"
    self:_save(attempt, state)
    self:_save(taskRoot .. "/draft.json", {attempt=attempt})
    return view_for(self, state, attempt, tree, taskRoot)
end
function Worktree:close()
    if self.root then self.root:close(); self.root = nil end
end

function View:set_provenance(author, origin)
    assert(known(author) and (origin == "agent" or origin == "external"), "trusted author and origin are required")
    self.author = {alias=trim(author.alias), model=trim(author.model)}
    self.origin = origin
end
function View:_save(state)
    self.manager:_save(self.attempt, state)
    self.state, self.index = state, self.manager:_read(state.files["notebook/index.md"]) or ""
end
function View:read(path, draft)
    source_path(path)
    if draft then
        local source = self:_draft_source(draft, path)
        assert(not source.change.delete, "archived source is a deletion")
        return self.manager:_read(source.change.blob)
    end
    return self.manager:_read(assert(self.state.files[path], "source does not exist: " .. path))
end
function View:list() return keys(self.state.files) end
function View:published(path)
    for _, file in ipairs(self.snapshot.files) do
        if file.name == path then return self.manager:_read(file.blob) end
    end
end
function View:write(path, text)
    source_path(path)
    assert(known(self.author), "staging needs a trusted model author")
    assert(text ~= nil or path ~= "notebook/index.md", "the notebook index cannot be deleted")
    assert(text ~= nil or self.state.files[path] ~= nil, "source does not exist: " .. path)
    local state = copy(self.state)
    state.files[path] = text and self.manager:_put(path, text) or nil
    bundle(self.manager, state.files)
    local old = state.provenance[path] or {}
    state.provenance[path] = {digest=digest(state.files[path]), origin=old.origin == "external" and "external" or self.origin,
        authors=author_list(old.authors, self.author)}
    self:_save(state)
    return true
end

-- This local check covers portable source bounds and the notebook layout.
-- Complete Markdown parsing, secret patterns, manifests and semantic admission
-- remain the receiving server's checks; a passing local check is not approval.
local function layout_check(manager, before, after)
    local structured = (manager:_read(after["notebook/index.md"]) or ""):match("^[^\r\n]*") == MARKER
    local was = (manager:_read(before["notebook/index.md"]) or ""):match("^[^\r\n]*") == MARKER
    assert(not was or structured, "retain the adopted notebook layout marker")
    if not structured then return "legacy" end
    local directories = {knowledge=true, objects=true, history=true, context=true}
    for name, text in pairs(after) do
        if name:sub(1,9) == "notebook/" then
            if name ~= "notebook/index.md" then
                local section = name:match("^notebook/([^/]+)/")
                assert(section and ({knowledge=true, objects=true, history=true, context=true})[section], "note needs a notebook layout section: " .. name)
                for part in name:sub(10):gmatch("[^/]+") do
                    assert(part:match("^[a-z0-9][a-z0-9.-]*$") and not part:find("[.-][.-]") and not part:match("[.-]$"), "note needs a portable lowercase name: " .. name)
                end
                local dir = name:match("^notebook/(.*)/[^/]+$")
                while dir do directories[dir] = true; dir = dir:match("^(.*)/[^/]+$") end
            end
            if name:match("/index%.md$") then
                text = manager:_read(text)
                assert(lines(text) <= 80 and utf8.len(text) <= 12000, "directory index exceeds its layout bound: " .. name)
            end
        end
    end
    for dir in pairs(directories) do assert(after["notebook/" .. dir .. "/index.md"], "missing notebook directory index: " .. dir) end
    return "1"
end
function View:check(paths)
    local before = file_map(self.state.commitBase)
    local changes = changed(before, self.state.files, paths)
    local after = applied(before, changes)
    local result = {passed=true, scope="source-bounds-and-layout", issues=json.array()}
    local ok, err = pcall(function()
        result.checkedFiles = bundle(self.manager, after)
        for _, change in ipairs(changes) do
            assert(not change.delete or change.name ~= "notebook/index.md", "the notebook index cannot be deleted")
        end
        result.layout = layout_check(self.manager, before, after)
        result.semanticReviewRequired = result.layout == "1"
        for _, change in ipairs(changes) do
            if change.name:sub(1,9) ~= "notebook/" then result.semanticReviewRequired = true end
        end
    end)
    if not ok then result.passed=false; result.issues[1]={severity="error", detail=tostring(err)} end
    return result
end
function View:status()
    local result = {}
    for _, change in ipairs(changed(self.state.checkpoint, self.state.files)) do
        result[#result+1] = (change.delete and "D" or self.state.checkpoint[change.name] == nil and "A" or "M") .. " " .. change.name
    end
    return table.concat(result, "\n")
end
function View:diff(paths)
    if type(paths) == "string" then paths = {paths} end
    local result = json.array()
    for _, change in ipairs(changed(self.state.checkpoint, self.state.files, paths)) do
        result[#result+1] = {name=change.name, beforeExists=self.state.checkpoint[change.name] ~= nil,
            before=self.manager:_read(self.state.checkpoint[change.name]) or "", afterExists=not change.delete, after=self.manager:_read(change.blob) or ""}
    end
    return result
end
function View:log(limit)
    limit = limit or 10
    assert(type(limit) == "number" and limit % 1 == 0 and limit >= 1 and limit <= 50,
        "history limit must be between 1 and 50")
    local manager = self.manager
    local binding = assert(manager:_binding(false), "worktree assignment was removed")
    assert(same_tree(binding, self.snapshot), "history belongs to another worktree assignment")
    local commits, entries, seen, cursors = json.array(), {}, {}, {}
    local cursor, revision = "", self.revision
    if revision == "" then return commits end
    -- Match the static client's bounded scan. Display order is proposal order;
    -- only publishedBaseRevision identifies the immutable Git parent.
    for _ = 1, 20 do
        local page = manager:_request("GET", API .. "/history?worktreeId=" .. escape(binding.worktreeId) ..
            "&cursor=" .. escape(cursor) .. "&limit=50")
        assert(type(page.entries) == "table" and #page.entries <= 50, "history exceeds its page bound")
        for _, entry in ipairs(page.entries) do
            if entry.state == "published" and entry.revision and entry.revision ~= "" then entries[entry.revision] = entry end
        end
        while revision ~= "" and entries[revision] do
            assert(not seen[revision], "history contains a revision cycle")
            seen[revision] = true
            local entry = entries[revision]
            commits[#commits+1] = {hash=revision, message=entry.message, when=entry.publishedAt}
            revision = entry.publishedBaseRevision or ""
            if #commits == limit then return commits end
        end
        if revision == "" then return commits end
        local nextCursor = page.nextCursor or ""
        assert(nextCursor ~= "", "pinned revision or its parent is missing from history")
        assert(#nextCursor <= 512 and nextCursor ~= cursor and not cursors[nextCursor], "history cursor did not advance")
        cursor, cursors[nextCursor] = nextCursor, true
    end
    error("history exceeds the bounded page scan; enter a newer attempt")
end
function View:show(revision, path)
    source_path(path)
    local snapshot = self.snapshot
    if revision and revision ~= "" and revision ~= "HEAD" and revision ~= self.revision then
        local binding = assert(self.manager:_binding(false), "worktree assignment was removed")
        assert(same_tree(binding, self.snapshot), "history belongs to another worktree assignment")
        binding.revision = revision
        snapshot = self.manager:_snapshot(binding, false)
    end
    return self.manager:_read(assert(file_map(snapshot)[path], "source does not exist at the published revision: " .. path))
end
function View:submit(paths, message, basis)
    assert(type(paths) == "table" and #paths > 0, "a proposal needs exact paths")
    message, basis = trim(message), trim(basis)
    if basis == "" then basis = message end
    assert(message ~= "" and #message <= 1000 and basis ~= "" and #basis <= 4000, "proposal message or basis exceeds its bounds")
    assert(known(self.author) and (self.origin == "agent" or self.origin == "external"), "proposal needs trusted author and origin")
    local manager = self.manager
    manager:sync()
    for _, queued in ipairs(manager:_outbox()) do
        if queued.taskRoot == self.taskRoot then
            local pub = manager:_load("publications/" .. queued.proposal.id .. ".json")
            if pub then manager:_acknowledge(queued, pub, self.attempt) end
        end
    end
    self.state = assert(manager:_load(self.attempt))
    local baseline = file_map(self.state.commitBase)
    local changes = changed(baseline, self.state.files, paths)
    assert(#changes > 0, "no source changes selected")
    local check = self:check(paths)
    assert(check.passed, check.issues[1] and check.issues[1].detail)
    local selected = {}
    local authors, origin = author_list(nil, self.author), self.origin
    for _, change in ipairs(changes) do
        selected[change.name] = true
        assert(self.state.observed[change.name] == baseline[change.name], "source changed on the server; enter a new attempt before committing: " .. change.name)
        local mark = self.state.provenance[change.name]
        assert(mark and mark.digest == digest(self.state.files[change.name]), "source has no matching staged provenance: " .. change.name)
        if mark.origin == "external" then origin = "external" end
        for _, author in ipairs(mark.authors) do authors = author_list(authors, author) end
    end
    assert(#authors <= 64, "proposal has more than 64 contributing authors")
    for _, queued in ipairs(manager:_outbox()) do
        if same_tree(queued.binding, self.snapshot) then
            local pub = manager:_load("publications/" .. queued.proposal.id .. ".json")
            local prior = manager:_load(queued.attempt)
            local done = pub and terminal[pub.state] and (pub.state ~= "published" or prior.acknowledged[pub.id])
            if not done then
                for _, change in ipairs(queued.proposal.changes) do assert(not selected[change.name], "source has an unresolved earlier proposal: " .. change.name) end
            end
        end
    end
    local proposal = {id=core.identifier(), baseRevision=self.state.commitBase.revision, message=message,
        basis=basis, changes=manager:_contents(changes), origin=origin, author=copy(self.author), authors=authors, taskId=self.state.taskId}
    local sequencePath = self.taskRoot .. "/sequence.json"
    local sequence = (manager:_load(sequencePath) or 0) + 1
    manager:_save(sequencePath, sequence)
    local queued = {proposal=proposal, binding={workspaceId=self.snapshot.workspaceId, worktreeId=self.snapshot.worktreeId},
        taskRoot=self.taskRoot, attempt=self.attempt, sequence=sequence}
    -- Save the complete immutable request before any network operation. A
    -- lost response only resends these bytes under this same identifier.
    manager:_save("outbox/" .. proposal.id .. ".json", queued)
    local state = copy(self.state)
    state.checkpoint = applied(state.checkpoint, changes)
    self:_save(state)
    local ok, publication = pcall(manager._send, manager, queued)
    if not ok then
        local status = status_of(publication)
        if status and status < 500 then error(publication, 0) end
        return {id=proposal.id, state="queued"}
    end
    self.state = assert(manager:_load(self.attempt))
    return publication
end

function View:_drafts()
    local result = {}
    for _, directory in ipairs(self.manager:_entries(self.tree .. "/drafts")) do
        if directory.kind == "directory" then
            local taskRoot = self.tree .. "/drafts/" .. directory.name
            local pointers = {}
            if taskRoot ~= self.taskRoot then
                local pointer = self.manager:_load(taskRoot .. "/draft.json")
                if pointer then pointers[#pointers+1] = pointer end
            end
            for _, archive in ipairs(self.manager:_entries(taskRoot .. "/archives")) do
                if archive.kind == "file" and archive.name:match("%.json$") then
                    pointers[#pointers+1] = self.manager:_load(taskRoot .. "/archives/" .. archive.name)
                end
            end
            for _, pointer in ipairs(pointers) do
                local state = assert(self.manager:_load(pointer.attempt), "archived draft is missing")
                if state.ownerId == self.state.ownerId and same_tree(state.snapshot, self.snapshot) then
                    bundle(self.manager, state.files)
                    result[state.id] = {state=state, conflicts=pointer.conflicts}
                end
            end
        end
    end
    return result
end
function View:drafts()
    local result = json.array()
    for id, draft in pairs(self:_drafts()) do
        local paths = json.array()
        for _, change in ipairs(changed(draft.state.observed, draft.state.files)) do paths[#paths+1] = change.name end
        if #paths > 0 then result[#result+1]={id=id, taskId=draft.state.taskId, revision=draft.state.snapshot.revision, paths=paths, conflicts=draft.conflicts} end
    end
    table.sort(result, function(a,b) return a.id < b.id end)
    return result
end
function View:_draft_source(id, path)
    local draft = assert(self:_drafts()[id], "private draft does not exist for this owner and worktree")
    for _, change in ipairs(changed(draft.state.observed, draft.state.files)) do
        if change.name == path then return {change=change, mark=draft.state.provenance[path]} end
    end
    error("source is not changed in the private draft: " .. path)
end
function View:restore(id, path)
    source_path(path)
    local source = self:_draft_source(id, path)
    local ref = not source.change.delete and source.change.blob or nil
    assert(ref ~= nil or path ~= "notebook/index.md", "the notebook index cannot be deleted")
    assert(source.mark and source.mark.digest == digest(ref), "archived source has no matching provenance; read and stage it explicitly")
    local state = copy(self.state)
    state.files[path] = ref
    bundle(self.manager, state.files)
    local mark = copy(source.mark)
    local prior = state.provenance[path]
    if prior then
        if prior.origin == "external" then mark.origin = "external" end
        for _, author in ipairs(prior.authors) do mark.authors=author_list(mark.authors, author) end
    end
    state.provenance[path] = mark
    self:_save(state)
    return true
end

function View:search(query, limit)
    query, limit = trim(query), limit or 5
    local size = utf8.len(query)
    assert(size and size >= 3 and size <= 500 and limit >= 1 and limit <= 10 and limit % 1 == 0,
        "search needs a 3-500 character query and a limit between 1 and 10")
    if #changed(file_map(self.snapshot), self.state.files) == 0 then
        local ok, answer = pcall(self.manager._request, self.manager, "GET", API .. "/search?revision=" .. escape(self.revision) .. "&q=" .. escape(query) .. "&limit=" .. limit)
        if ok and answer.revision == self.revision then
            for _, hit in ipairs(answer.result.hits) do source_path("notebook/" .. hit.path) end
            answer.result.detail = answer.detail
            return answer.result
        end
    end
    -- The portable fallback is deliberately labelled: it has no Snowball
    -- stemming, Unicode normalization, BM25 or local embedding dependency.
    local words = {}
    for word in query:lower():gmatch("[^%s%p]+") do words[#words+1] = word end
    assert(#words > 0, "search query needs words or identifiers")
    local hits, total = json.array(), 0
    for _, path in ipairs(keys(self.state.files)) do
        if path:sub(1,9) == "notebook/" then
            total = total + 1
            local text = self.manager:_read(self.state.files[path])
            local first, lineNumber = nil, 0
            for line in (text .. "\n"):gmatch("(.-)\n") do
                lineNumber = lineNumber + 1
                for _, word in ipairs(words) do
                    if line:lower():find(word, 1, true) then first=lineNumber; break end
                end
                if first then break end
            end
            if first then
                local excerpt, last, number = {}, first, 0
                for line in (text .. "\n"):gmatch("(.-)\n") do
                    number = number + 1
                    if number >= first and number < first + 20 then excerpt[#excerpt+1]=line; last=number end
                end
                excerpt = table.concat(excerpt, "\n")
                local cut = utf8.offset(excerpt, 901)
                if cut then excerpt=excerpt:sub(1,cut-1) end
                local hit = {path=path:sub(10), heading=text:match("^#+%s+([^\n]+)") or path:sub(10),
                    from_line=first, to_line=math.min(last, lines(text)), excerpt=excerpt}
                if hit.path:match("^history/cases/") then hit.caseFreshness="unchecked" end
                if #hits < limit then hits[#hits+1] = hit end
            end
        end
    end
    while #hits > limit do table.remove(hits) end
    return {mode="lexical", semantic="unavailable", indexed_chunks=0, total_chunks=total, hits=hits,
        detail="Local literal word search over this draft; stemming, semantic ranking and the published search index are unavailable."}
end

return Worktree
