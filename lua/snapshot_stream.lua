-- Snapshot framing only: decode one file or top-level metadata value at a
-- time. The caller must publish its index only after finish() succeeds; an
-- invalid tail can follow files already delivered to content-addressed storage.
local json = require("json")
local Stream = {}
Stream.__index = Stream
-- Worktree sources allow 1 MiB of UTF-8 text and 512 path bytes. Each byte
-- can occupy six JSON bytes; the remaining room is the name/text framing.
local MAX_FILE_JSON = 6*1048576 + 6*512 + 64

function Stream.new(on_file, field)
    assert(type(on_file) == "function", "snapshot stream needs a file callback")
    return setmetatable({on_file=on_file, field=field or "files", state="start", metadata={}, seen={}}, Stream)
end

function Stream:_append(piece)
    if piece == "" then return end
    self.size = self.size + #piece
    assert(self.role ~= "file" or self.size <= MAX_FILE_JSON, "snapshot file JSON exceeds its bound")
    -- Coalesce tiny feed fragments so a byte-at-a-time caller does not need
    -- one table slot per source byte. This is a block size, not a source limit.
    if #piece >= 4096 then
        if self.smallSize > 0 then
            self.parts[#self.parts+1]=table.concat(self.small)
            self.small,self.smallSize={},0
        end
        self.parts[#self.parts+1]=piece
    else
        self.small[#self.small+1]=piece
        self.smallSize=self.smallSize+#piece
        if self.smallSize >= 4096 then
            self.parts[#self.parts+1]=table.concat(self.small)
            self.small,self.smallSize={},0
        end
    end
end

function Stream:_begin(first, role)
    self.role,self.state,self.parts,self.small,self.smallSize,self.size=role,"token",{},{},0,0
    self.quoted,self.escaped,self.depth=first == '"',false,0
    if first == "{" or first == "[" then self.kind,self.depth="container",1
    elseif first == '"' then self.kind="string"
    else self.kind="primitive" end
    self:_append(first)
end

function Stream:_value()
    if self.smallSize > 0 then self.parts[#self.parts+1]=table.concat(self.small) end
    local raw=table.concat(self.parts)
    self.parts,self.small,self.smallSize,self.size=nil,nil,nil,nil
    local value=json.decode(raw)
    raw=nil
    if self.role == "key" then
        assert(type(value) == "string" and not self.seen[value], "snapshot field is invalid or duplicated")
        self.seen[value],self.key,self.state=true,value,"colon"
    elseif self.role == "metadata" then
        self.metadata[self.key],self.key,self.state=value,nil,"separator"
    else
        assert(type(value) == "table" and value ~= json.null, "stream item must be an object")
        if self.field == "files" then
            assert(type(value.name) == "string" and type(value.text) == "string", "snapshot file needs name and text")
        end
        self.state="file-separator"
        self.on_file(value)
    end
end

function Stream:_token(chunk, at)
    local first, complete=at,false
    while at <= #chunk and not complete do
        if self.quoted then
            if self.unicode and self.unicode > 0 then
                assert(chunk:sub(at,at):match("^[%da-fA-F]$"), "invalid JSON Unicode escape")
                self.unicode=self.unicode-1; at=at+1
            elseif self.escaped then
                local escaped=chunk:sub(at,at)
                assert(escaped:match('^["\\/bfnrtu]$'), "invalid JSON string escape")
                if escaped == "u" then self.unicode=4 end
                self.escaped=false; at=at+1
            else
                local nextAt=chunk:find('["\\%z\1-\31]',at)
                if not nextAt then at=#chunk+1
                else
                    local char=chunk:sub(nextAt,nextAt)
                    assert(char:byte() >= 32, "unescaped JSON control character")
                    if char == "\\" then self.escaped=true
                    else self.quoted=false; complete=self.kind == "string" end
                    at=nextAt+1
                end
            end
        elseif self.kind == "primitive" then
            local nextAt=chunk:find('[ \t\r\n,%]}]',at)
            if not nextAt then at=#chunk+1
            else at=nextAt; complete=true end
        else
            local nextAt=chunk:find('[{}%[%]"]',at)
            if not nextAt then at=#chunk+1
            else
                local char=chunk:sub(nextAt,nextAt)
                if char == '"' then self.quoted=true
                elseif char == "{" or char == "[" then self.depth=self.depth+1
                else self.depth=self.depth-1; complete=self.depth == 0 end
                at=nextAt+1
            end
        end
    end
    self:_append(chunk:sub(first,at-1))
    if complete then self:_value() end
    return at
end

function Stream:feed(chunk)
    assert(not self.failed, "snapshot stream has already failed or is inside its callback")
    self.failed=true
    assert(type(chunk) == "string", "snapshot chunk must be a string")
    local at=1
    while at <= #chunk do
        if self.state == "token" then at=self:_token(chunk,at)
        else
            at=chunk:find('[^ \t\r\n]',at) or #chunk+1
            if at <= #chunk then
                local char,state=chunk:sub(at,at),self.state
                if state == "start" then
                    assert(char == "{", "snapshot must be an object")
                    self.state="first-key"
                elseif state == "first-key" or state == "next-key" then
                    if char == "}" and state == "first-key" then self.state="done"
                    else
                        assert(char == '"', "snapshot needs a field name")
                        self:_begin(char,"key")
                    end
                elseif state == "colon" then
                    assert(char == ":", "snapshot field needs a colon")
                    self.state="value"
                elseif state == "value" then
                    if self.key == self.field then
                        assert(char == "[", "snapshot files must be an array")
                        self.key,self.state=nil,"first-file"
                    else
                        assert(char ~= "," and char ~= "}" and char ~= "]", "snapshot field needs a value")
                        self:_begin(char,"metadata")
                    end
                elseif state == "first-file" or state == "next-file" then
                    if char == "]" and state == "first-file" then self.state="separator"
                    else
                        assert(char == "{", "snapshot file must be an object")
                        self:_begin(char,"file")
                    end
                elseif state == "file-separator" then
                    if char == "]" then self.state="separator"
                    else assert(char == ",", "snapshot files need a comma"); self.state="next-file" end
                elseif state == "separator" then
                    if char == "}" then self.state="done"
                    else assert(char == ",", "snapshot fields need a comma"); self.state="next-key" end
                else error("trailing snapshot data") end
                at=at+1
            end
        end
    end
    self.failed=false
end

function Stream:finish()
    assert(not self.failed and self.state == "done" and self.seen[self.field], "incomplete or invalid snapshot stream")
    return self.metadata
end

return Stream
