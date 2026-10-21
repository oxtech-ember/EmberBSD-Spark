package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestDesktopAcceptsOnlyPendingLocalMCPDeclarations(t *testing.T) {
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	modules, err := filepath.Abs("../lua")
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(directory, "desktop.lua")
	if err := os.WriteFile(script, []byte(desktopAcceptanceScenario), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "../build/agent-lua", script, modules, directory)
	cmd.Env = append(os.Environ(), "OXTORG_MCP="+directory)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("desktop acceptance: %v\n%s", err, output)
	}
}

const desktopAcceptanceScenario = `
package.path=arg[1] .. "/?.lua;" .. package.path
local json,fs,Desktop=require("json"),require("asenta.fs"),require("desktop")
local root=assert(fs.root(arg[2],false))
local name="accepted/foreign.json"
local first={name="first",description="Previously accepted",inputSchema={type="object"}}
local changed={name="changed",description="Changed declaration",inputSchema={type="object"},
    annotations={readOnlyHint=true,openWorldHint=false}}
local added={name="added",inputSchema={type="object"}}
assert(root:write(name,json.encode{server="stdio|/installed/foreign|[]",accepted={first=first},
    pending={changed=changed,added=added}}))
local names=Desktop.accept_tools(nil,"foreign")
assert(#names==2 and names[1]=="added" and names[2]=="changed")
local kept=json.decode(assert(root:read(name)))
assert(kept.server=="stdio|/installed/foreign|[]" and kept.pending==nil)
assert(kept.accepted.first.description==first.description)
assert(kept.accepted.changed.description==changed.description)
assert(kept.accepted.changed.annotations.openWorldHint==false)
assert(kept.accepted.added.name=="added")
assert(#Desktop.accept_tools(arg[2],"foreign")==0,"repeated acceptance is not idempotent")
local stable=assert(root:read(name))
for _,alias in ipairs({"", ".", "..", "../foreign", "foreign/../../outside", string.rep("a",65)}) do
    assert(not pcall(Desktop.accept_tools,arg[2],alias),"invalid alias accepted")
end
assert(not pcall(Desktop.accept_tools,arg[2],"missing"),"missing record accepted")
assert(not pcall(Desktop.accept_tools,"","foreign"),"missing root accepted")
assert(root:read(name)==stable,"rejected command changed another record")
assert(root:write("accepted/empty.json",'{"server":"fixture","accepted":null,"pending":null}'))
assert(#Desktop.accept_tools(arg[2],"empty")==0)
assert(#Desktop.accept_tools(arg[2],"empty")==0,"empty declaration maps changed JSON shape")
for _,body in ipairs({'[]','{"server":"fixture","accepted":[],"pending":{}}',
    '{"server":"fixture","accepted":{},"pending":{"x":{"name":"y"}}}',"torn"}) do
    assert(root:write("accepted/broken.json",body))
    assert(not pcall(Desktop.accept_tools,arg[2],"broken"),"malformed record accepted")
    assert(root:read("accepted/broken.json")==body,"malformed record overwritten")
end
root:close()

-- Composition must hand the same directory to MCP that the desktop command
-- received. An adapter-local default would let acceptance succeed elsewhere.
local Client,MCP,Installation=require("client"),require("mcp"),require("installation")
function Client.new(config)
    return {config=config,request=function(_,method,path)
        assert(method=="GET" and path=="/api/v1/me")
        return {user={userId="fixture"},organization={orgId="fixture"}}
    end}
end
function Installation.rig() return {{alias="foreign",url="unused"}},{} end
local observed
function MCP.connect(_,options)
    observed=options.mcpRoot
    return {report=function() return {connected=true} end,close=function() end}
end
local App=require("application")
local config={server={baseUrl="http://fixture.invalid"},limits={}}
local app=App.new(config,{stateRoot=arg[2] .. "/state"})
assert(observed==arg[2],"application ignored the desktop's MCP directory")
app:close()
app=App.new(config,{stateRoot=arg[2] .. "/state",mcpRoot=arg[2] .. "/explicit"})
assert(observed==arg[2] .. "/explicit","explicit MCP root was ignored")
app:close()
`
