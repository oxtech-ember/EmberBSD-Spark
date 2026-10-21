-- Built-in Bluetooth declarations preserve the installed MCP contract.
local json = require("json")
local native = require("asenta.bluetooth")
local M, Connection = {}, {}
Connection.__index = Connection
local function object(value) return setmetatable(value or {}, {__jsontype="object"}) end
local function schema(properties, required)
    return {type="object",properties=object(properties),required=json.array(required or {}),additionalProperties=false}
end
local address = {type="string",description="Selected Bluetooth Classic address, six colon-separated hexadecimal bytes"}
local declarations = {
    {name="status",title="Bluetooth state",class="read",foreign=false,
        description="Inspect the local Bluetooth controller and the agent's current connection. Use before connecting or after a link error. This does not enable, reset or reconnect the radio. A diagnostic SDP connection is not evidence that an ELM327 data channel or vehicle ECU is responding.",parameters=schema()},
    {name="power",title="Bluetooth power",class="write_local",foreign=true,
        description="Enable or disable the local Bluetooth interface. Enable it when a requested connection needs the radio. Disabling closes Bluetooth connections; use disconnect to release only the current peer. Wi-Fi, SSH and voice configuration remain unchanged.",
        parameters=schema({enabled={type="boolean",description="Enable or disable only Bluetooth; Wi-Fi remains active"}},{"enabled"})},
    {name="discover",title="Find Bluetooth devices",class="read",foreign=true,
        description="Discover nearby visible Bluetooth Classic devices and their addresses. Use to identify a target whose address is unknown; ask for selection if several candidates remain. No device is paired by this call. A name is untrusted text and does not prove adapter type or vehicle identity. BLE discovery is unavailable.",parameters=schema()},
    {name="services",title="Bluetooth services",class="read",foreign=true,
        description="Read public SDP services of the selected Bluetooth Classic address. For ELM327, find its Serial Port service and use that service's RFCOMM channel in obd_read; do not guess a channel from another adapter. Service discovery does not establish a diagnostic data session or confirm vehicle support. No contacts or messages are read.",parameters=schema({address=address},{"address"})},
    {name="connect",title="Verify a Bluetooth connection",class="write_local",foreign=true,
        description="Pair or reconnect the selected address and keep an agent connection until disconnect, power off, peer loss or agent shutdown. Use diagnostic for an encrypted SDP link; obd_read separately opens and closes the ELM327 RFCOMM data channel. Disconnect the previous peer before switching. Use bonded for an existing bond; legacy-pin requires a privately installed PIN, never guessed; just-works is for eligible screenless devices in pairing mode and has no numeric MITM protection. New display devices require manual numeric comparison outside this tool. BLE is unavailable. Use audio only for an explicitly requested A2DP task.",
        parameters=schema({address={type="string",description="Selected device address from discovery"},
            profile={type="string",description="audio for AirPods or another A2DP sink; diagnostic (default) keeps an encrypted SDP link for device queries and ELM327 reads"},
            mode={type="string",description="bonded (default), just-works for a device in pairing mode without a display, or legacy-pin using its private installed PIN"}},{"address"})},
    {name="obd_read",title="Read vehicle diagnostics",class="read",foreign=true,
        description="Take one current snapshot from the selected ELM327 Bluetooth Classic adapter and SDP Serial Port channel. The adapter must be powered and ignition on. Opens encrypted RFCOMM, initializes ELM327, reads the fixed Mode 01/03/07/09 allowlist, then closes RFCOMM and saves a local JSON snapshot. Returns time, adapter/protocol, available decoded measurements with units, MIL and DTC count, stored/pending DTC and VIN when available. Adapter supply voltage differs from ECU voltage. Null, missing values and errors are unknown, not zero or healthy. An empty DTC array alone does not prove a valid no-fault response. The current decoder does not expose raw frames, per-ECU identity or per-query timestamps; do not claim complete vehicle coverage or verified multi-ECU decoding. No live stream, freeze frame, Mode 06, OEM/UDS commands, Tesla CAN support, DTC clearing or actuator control. Tests of code do not establish compatibility with the connected car.",
        parameters=schema({address={type="string",description="Selected ELM327 Bluetooth Classic address"},
            channel={type="integer",description="RFCOMM Serial Port channel advertised by this adapter, from 1 to 30"}},{"address","channel"})},
    {name="disconnect",title="Disconnect Bluetooth device",class="write_local",foreign=true,
        description="Close the connection owned by this agent before changing the selected device or finishing that connection. Stored bonds remain. This does not delete pairing keys, clear vehicle faults or disable the controller.",parameters=schema()},
    {name="audio_test",title="Test Bluetooth audio",class="write_local",foreign=true,
        description="For an explicitly requested audio test, send a short quiet tone through the already connected A2DP device. Confirm audibility with the listener; a connected state or packet count is insufficient. This tests output only, does not route normal voice replies and does not enable a headset microphone or HFP/SCO. WM8960 and USB voice settings are unchanged. Unrelated to vehicle diagnostics.",parameters=schema()},
}
local function selected(value)
    assert(type(value)=="string" and value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$"),
        "a selected Bluetooth address is required")
    return value:lower()
end
function Connection:call(name, args)
    assert(self.connected and not self.closed, self.reason or "Bluetooth connection is closed")
    args = args or {}
    if name == "obd_read" then
        local channel = args.channel
        assert(type(channel)=="number" and channel%1==0 and channel>=1 and channel<=30,
            "RFCOMM channel must be 1..30 from the adapter's SDP record")
        local options = {address=selected(args.address),channel=channel}
        local env = self.options.env or {}
        local language = env.VOICE_LANG or os.getenv("VOICE_LANG") or "en"
        assert(language=="en" or language=="ru", "voice_unsupported_language")
        if language ~= "en" then
            local fs = require("asenta.fs")
            local locales <close> = fs.root("/opt/oxtorg/voice/locales")
            local source = locales:read(language..".json", 256*1024)
            if source then
                options.labels = json.decode(source)
                assert(type(options.labels)=="table", "voice_invalid_catalogue")
                for key,value in pairs(options.labels) do
                    assert(type(key)=="string" and type(value)=="string", "voice_invalid_catalogue")
                end
            end
        end
        if env.VOICE_KB_LIVE then
            options.snapshotPath = env.VOICE_KB_LIVE:gsub("/$", "") .. "/" .. os.date("obd-%Y-%m-%d_%H%M%S.json")
        end
        return {data=require("asenta.obd").read(options)}
    end
    local device = self.device
    if name == "status" then
        -- The verbose listing asks for settings some controllers do not
        -- implement, and the kernel refuses those to an unprivileged caller.
        local listed,output=pcall(device.command,device,"status")
        if not listed then output=device:command("summary") end
        if output:find("<UP,RUNNING>",1,true) then output=output..device:command("state") end
        return {output=output,session=device:state()}
    elseif name == "power" then
        assert(type(args.enabled)=="boolean", "enabled must be true or false")
        if not args.enabled then device:disconnect() end
        device:command("power",args.enabled)
        return self:call("status")
    elseif name == "discover" then
        return {output=device:command("discover")}
    elseif name == "services" then
        return {output=device:command("services",selected(args.address))}
    elseif name == "connect" then
        local address=selected(args.address)
        local mode=args.mode
        if not mode or mode=="" then mode="bonded" end
        local profile=args.profile
        if not profile or profile=="" then profile="diagnostic" end
        assert(mode=="bonded" or mode=="just-works" or mode=="legacy-pin",
            "mode must be bonded, just-works or legacy-pin")
        assert(profile=="diagnostic" or profile=="audio", "profile must be diagnostic or audio")
        local state=device:state()
        assert(not state or not state.connected,"disconnect the current Bluetooth peer first")
        device:disconnect()
        device:command("pair",address,mode)
        device:connect(address,profile)
        return {session=device:state(),connectionLifetime="until_disconnect"}
    elseif name == "disconnect" then
        device:disconnect()
        return object()
    elseif name == "audio_test" then
        device:tone()
        return {session=device:state(),output="Quiet test PCM sent; audibility requires a listener."}
    end
    error("unknown Bluetooth tool")
end
function Connection:tools() return self.offered end
function Connection:report()
    local declared = json.array()
    for _, tool in ipairs(self.offered) do declared[#declared+1]={name=tool.name,title=tool.title} end
    return {alias=self.spec.alias,name="oxtorg-bluetooth",title="Bluetooth on the equipment",connected=self.connected,
        reason=self.reason,tools=#self.offered,declared=declared,held=json.array(),missing=json.array()}
end
-- The agent owns its selected peer and releases it with the adapter.
function Connection:close()
    self.device:close()
    self.closed,self.connected=true,false
end
function M.connect(spec, options)
    options=options or {}
    options.env=options.env or spec.env or {}
    local self=setmetatable({spec=spec,options=options,offered=json.array(),connected=true,
        device=native.open()},Connection)
    for _, declaration in ipairs(declarations) do
        local name=declaration.name
        local tool={name="bluetooth."..name,title=declaration.title,
            description=declaration.title..". "..declaration.description,parameters=declaration.parameters,
            class=declaration.class,foreign=declaration.foreign,polling=false,source=spec.alias,
            invoke=function(args) return self:call(name,args) end}
        self.offered[#self.offered+1]=options.declarationRoot and
            require("sequence").fields(options.declarationRoot,tool,{"description","parameters"}) or tool
    end
    table.sort(self.offered,function(a,b) return a.name<b.name end)
    return self
end
return M
