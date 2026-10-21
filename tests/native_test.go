package probe

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestNativeConnectionsKeepInstallationPolicyAndRig(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "native.lua")
	if err := os.WriteFile(script, []byte(nativeScenario), 0600); err != nil {
		t.Fatal(err)
	}
	modules, err := filepath.Abs("../lua")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "../build/agent-lua", script, modules, dir)
	cmd.Env = append(os.Environ(), "NATIVE_EMPTY_UNITS=")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("native connection: %v\n%s", err, out)
	}
}

const nativeScenario = `
package.path=arg[1] .. "/?.lua;" .. package.path
local Native,Installation,fs=require("native"),require("installation"),require("asenta.fs")
local root=assert(fs.root(arg[2],false))
local closed=false
local offered={{name="equipment.state",class="read",invoke=function() return {load1=0} end}}
package.preload.fixture_native=function() return {connect=function(spec,options)
  assert(options.env.EQUIPMENT_UNITS=="")
  assert(options.env.EXAMPLE=="installation")
  assert(options.root==root and options.declarationRoot==root)
  return {tools=function()return offered end,close=function()closed=true end,
    report=function()return {alias=spec.alias,connected=true,tools=1} end}
end} end
local spec={alias="equipment",module="fixture_native",env={EXAMPLE="installation"},
  envFrom={EQUIPMENT_UNITS="NATIVE_EMPTY_UNITS"}}
local connection=Native.connect(spec,{root=root,declarationRoot=root})
assert(connection:report().connected)
assert(#connection:tools()[1].program==64 and connection:tools()[1].class=="read")
connection:close();assert(closed)
local bad=Native.connect({alias="bad",module="fixture_native",command="do-not-spawn"},{})
assert(not bad:report().connected and #bad:tools()==0)
local missing=Native.connect({alias="bad",module="fixture_native",envFrom={X="UNSET_NATIVE_FIXTURE_ENV"}},{})
assert(not missing:report().connected and missing:report().missing[1]=="UNSET_NATIVE_FIXTURE_ENV")
assert(root:write("oxtorg-mcp-equipment.passport.json",'{"name":"legacy","tools":[]}'))
local switches={{alias="equipment",enabled=false},{alias="equipment",enabled=true}}
local client={request=function()return {rig=switches} end}
local config={mcp={spec}}
local specs,passports=Installation.rig(config,client,{programDir=arg[2]})
assert(#specs==1 and specs[1].module=="fixture_native" and not specs[1].command)
assert(#passports==1 and passports[1].name=="fixture_native")
switches={{alias="equipment",enabled=false}}
specs,passports=Installation.rig(config,client,{programDir=arg[2]})
assert(#specs==0 and #passports==1)
-- A later restart re-enables the configured native adapter, never the old binary.
switches={{alias="equipment",enabled=true}}
specs=Installation.rig(config,client,{programDir=arg[2]})
assert(#specs==1 and specs[1].module=="fixture_native")
local json=require("json")
local given={roleFile="role.md",server={baseUrl="https://example.test",tokenEnv="TOKEN_NAME"},mcp={
  {alias="equipment",command="oxtorg-mcp-equipment",args={"-collect-history","1000"}},
  {alias="bluetooth",command="/opt/oxtorg/bin/oxtorg-mcp-bluetooth"},
  {alias="custom",command="/example/custom"}}}
assert(root:write("config.json",json.encode(given)))
local savedArg=arg
arg={savedArg[1],savedArg[2] .. "/config.json"}
assert(loadfile(savedArg[1] .. "/../emberbsd/native-config.lua"))()
arg=savedArg
local migrated=json.decode(assert(root:read("config.json.native")))
assert(migrated.server.tokenEnv=="TOKEN_NAME" and migrated.roleFile=="role.md")
assert(migrated.mcp[1].module=="equipment" and migrated.mcp[1].args[2]=="1000")
assert(migrated.mcp[2].module=="bluetooth" and not migrated.mcp[2].command)
assert(migrated.mcp[3].command=="/example/custom" and not migrated.mcp[3].module)
root:close()
`
