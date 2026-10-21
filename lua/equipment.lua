-- Native local measurements share the registry contract with owned MCP tools.
-- The C worker samples independently; this adapter only shapes declarations
-- and streams the retained window into the application's bounded storage.
local native, json = require("asenta.equipment"), require("json")
local Sequence = require("sequence")
local M, Connection = {}, {}
Connection.__index = Connection

local function duration(text)
    if text == "0" then return 0 end
    local units = {ns=1e-9, us=1e-6, ms=1e-3, s=1, m=60, h=3600}
    local total, at = 0, 1
    while at <= #text do
        local first, last, value, unit = text:find("(%d*%.?%d+)([a-z]+)", at)
        assert(first == at and units[unit], "invalid equipment collection interval")
        total, at = total + tonumber(value) * units[unit], last + 1
    end
    assert(at > 1, "invalid equipment collection interval")
    return total
end
local flags = {
    ["collect-interval"]={"intervalSeconds",duration}, ["collect-history"]={"history",tonumber},
    ["collect-store"]={"store",function(value) return value end},
    ["collect-temperature"]={"temperatureCelsius",tonumber}, ["collect-load"]={"load",tonumber},
    ["collect-memory-percent"]={"memoryUsedPercent",tonumber},
}
local function configuration(spec, options)
    assert(type(options.env) == "table" and type(options.env.EQUIPMENT_UNITS) == "string",
        "EQUIPMENT_UNITS must be set, including an explicit empty value when no journal is allowed")
    local config = {root=options.root, units=options.env.EQUIPMENT_UNITS}
    for key, value in pairs(spec.machine or {}) do
        assert(key == "proc" or key == "sys" or key == "syslog", "unknown equipment source setting: " .. key)
        config[key] = value
    end
    local args, index = spec.args or {}, 1
    while index <= #args do
        local flag, value = args[index]:match("^%-%-?([^=]+)=(.*)$")
        if not flag then
            flag, value = args[index]:match("^%-%-?(.+)$"), args[index + 1]
            index = index + 1
        end
        local setting = flags[flag]
        assert(setting and type(value) == "string", "unsupported equipment collection option: " .. tostring(flag))
        config[setting[1]] = assert(setting[2](value), "invalid equipment collection option: " .. flag)
        index = index + 1
    end
    return config
end
local function arguments(args, allowed)
    assert(type(args) == "table", "tool arguments must be an object")
    for key in pairs(args) do assert(allowed[key], "unexpected argument: " .. tostring(key)) end
end
local function integer(value, name)
    assert(value == nil or type(value) == "number" and value == math.floor(value), name .. " must be an integer")
    return value
end
local function schema(properties, required)
    return {type="object", properties=properties or setmetatable({}, {__jsontype="object"}),
        required=required or json.array(), additionalProperties=false}
end
function Connection:history(args)
    arguments(args, {limit=true})
    local result = self.handle:history(integer(args.limit, "limit"))
    local first, last, staleSince = result.first, result.last, result.staleSince
    result.first, result.last, result.staleSince = nil, nil, nil
    result.readings = self.options.root and Sequence.new(self.options.root) or json.array()
    result.gaps = json.array()
    local previous, previousTime
    for ordinal = first, last do
        local sample, acquired = self.handle:sample(ordinal)
        if previousTime and (acquired < previousTime or acquired - previousTime > 2 * result.intervalSeconds) then
            result.gaps[#result.gaps + 1] = {reason=acquired < previousTime and "clock_change" or "missing_samples",
                from=previous, to=sample.observedAt}
        end
        previous, previousTime = sample.observedAt, acquired
        result.readings[#result.readings + 1] = sample
    end
    if staleSince > 0 then
        result.gaps[#result.gaps + 1] = {reason="collection_stale", from=previous,
            to=os.date("!%Y-%m-%dT%H:%M:%SZ")}
    end
    return result
end
function Connection:tools() return self.offered end
function Connection:report()
    local declared = json.array()
    for _, tool in ipairs(self.offered) do declared[#declared + 1] = {name=tool.name, title=tool.title} end
    return {alias=self.spec.alias, name="oxtorg-equipment", title="Equipment", connected=not self.closed,
        tools=#self.offered, declared=declared, held=json.array(), missing=json.array()}
end
function Connection:close()
    if not self.closed then self.handle:close(); self.closed = true end
end
function M.connect(spec, options)
    options = options or {}
    local self = setmetatable({spec=spec, options=options, offered=json.array()}, Connection)
    self.handle = native.open(configuration(spec, options))
    local allowed = {}
    for unit in options.env.EQUIPMENT_UNITS:gmatch("[^,%s]+") do allowed[#allowed + 1] = unit end
    table.sort(allowed)
    local names = #allowed > 0 and table.concat(allowed, ", ") or "none - the installation named no services"
    local function add(name, title, description, parameters, invoke)
        local tool = {name=name, title=title, description=title .. ". " .. description,
            parameters=parameters, class="read", foreign=false, polling=false,
            source=spec.alias, program="", invoke=function(args)
                assert(not self.closed, "equipment connection is closed")
                return invoke(args or {})
            end}
        self.offered[#self.offered + 1] = options.declarationRoot and
            Sequence.fields(options.declarationRoot, tool, {"description", "parameters"}) or tool
    end
    add("equipment.alerts", "Machine collection alerts",
        "Stable health, source error and configured threshold state of local sensor collection. " ..
        "Contains no changing readings, uptime or timestamps, so compare this state to detect meaningful changes. " ..
        "Disabled collection, absent readings, missing configured sensors, collection gaps and storage failures are explicit. Reading only.",
        schema(), function(args) arguments(args, {}); return self.handle:alerts() end)
    add("equipment.history", "Collected machine readings",
        "Retained local machine sensor readings, sampled independently of tool calls when collection is enabled. " ..
        "Includes acquisition timestamps, partial readings, source errors and gaps. Only the bounded retained window is known; " ..
        "missing periods are not evidence of normal operation. Reading only.",
        schema({limit={type="integer", description="Maximum number of newest retained readings; 100 by default and 10000 at most. No data outside the retained window is implied."}}),
        function(args) return self:history(args) end)
    add("equipment.journal", "The journal of a service",
        "The last lines of a service's journal on this machine. Which services may be read is decided by the installation: " ..
        names .. ". A name outside that list is refused. Reads the current syslog file only; keeps at most 256 KiB. Reading only.",
        schema({unit={type="string", description="The service by the exact name the installation allowed."},
            lines={type="integer", description="Last lines to read; 100 by default, 500 at most."}}, json.array{"unit"}),
        function(args)
            arguments(args, {unit=true, lines=true})
            assert(type(args.unit) == "string", "unit must be a string")
            local text, truncated = self.handle:journal(args.unit, integer(args.lines, "lines"))
            if truncated then text = text .. "\nEarlier matching lines were omitted to keep the 256 KiB journal limit." end
            return text
        end)
    add("equipment.state", "The state of the machine",
        "How the machine beside the equipment is doing: load averages, uptime in seconds, total and available memory in KiB, " ..
        "and thermal zone temperatures in Celsius. A machine without thermometers reports an empty array. Reading only; nothing moves anything.",
        schema(), function(args) arguments(args, {}); return self.handle:state() end)
    return self
end
return M
