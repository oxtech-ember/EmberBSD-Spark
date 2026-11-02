-- Offline, bounded checks for an EmberBSD board.
-- Optional --video and --audio commands run only when explicitly supplied.
local process = require("asenta.process")
local equipment = require("asenta.equipment")
local core = require("asenta.core")

local function usage()
    io.stderr:write("Usage: board-selftest.lua [--video ABSOLUTE-PROGRAM [ARGS...] ] [--audio ABSOLUTE-PROGRAM [ARGS...] ]\n")
    os.exit(2)
end

local optional = {}
local index = 1
while index <= #arg do
    local kind = arg[index]
    if kind ~= "--video" and kind ~= "--audio" then usage() end
    index = index + 1
    local program = arg[index]
    if type(program) ~= "string" or program:sub(1, 1) ~= "/" then usage() end
    local argv = {program}
    index = index + 1
    while index <= #arg and arg[index] ~= "--video" and arg[index] ~= "--audio" do
        argv[#argv + 1] = arg[index]
        index = index + 1
    end
    optional[#optional + 1] = {name=kind:sub(3), argv=argv}
end

local function run(name, argv, include_output)
    local ok, result = pcall(function()
        local child <close> = process.spawn{
            argv=argv,
            env={PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/pkg/bin", LC_ALL="C", LANG="C", HOME="/tmp", TMPDIR="/tmp"},
            stdoutBytes=4096,
            stderrBytes=1024,
        }
        local deadline = core.monotonic_ms() + 10000
        local lines, total, ended = {}, 0, false
        while not ended do
            local remaining = deadline - core.monotonic_ms()
            if remaining <= 0 then
                child:close()
                return {name=name, status="timeout"}
            end
            local line, reason = child:receive(remaining, 1024)
            if line then
                total = total + #line + 1
                if total > 4096 then
                    child:close()
                    return {name=name, status="output_limit"}
                end
                lines[#lines + 1] = line
            elseif reason == "eof" then
                ended = true
            else
                child:close()
                return {name=name, status=reason or "read_error"}
            end
        end
        local exit_code
        repeat
            exit_code = child:status()
            if exit_code == nil then core.sleep(10) end
        until exit_code ~= nil or core.monotonic_ms() >= deadline
        local error_bytes = #child:stderr()
        child:close()
        local item = {
            name=name,
            status=exit_code == 0 and "pass" or (exit_code == nil and "timeout" or "fail"),
            exitCode=exit_code,
            stderrBytes=error_bytes,
        }
        if include_output then item.output = table.concat(lines, "\n") end
        return item
    end)
    if ok then return result end
    return {name=name, status="error"}
end

local checks = {
    run("kernel", {"/usr/bin/uname", "-srm"}, true),
    run("memory_pages", {"/usr/bin/env", "sysctl", "-n", "hw.ncpu"}, true),
    run("memory_bytes", {"/usr/bin/env", "sysctl", "-n", "hw.physmem"}, true),
    run("root_filesystem", {"/bin/df", "-k", "/"}, true),
}
for _, probe in ipairs(optional) do
    checks[#checks + 1] = run(probe.name, probe.argv, false)
end

local machine
local machine_ok, reading = pcall(function()
    local handle = equipment.open({})
    local ok, state = pcall(function() return handle:state() end)
    handle:close()
    if not ok then error(state) end
    return state
end)
if machine_ok then
    machine = {
        status="partial",
        uptimeSeconds=reading.uptimeSeconds,
        load1=reading.load1,
        load5=reading.load5,
        load15=reading.load15,
        memoryTotalKiB=reading.memoryTotalKb,
        memoryAvailableKiB=reading.memoryAvailableKb,
        temperatures=reading.temperatures,
    }
    if type(reading.uptimeSeconds) == "number" and reading.uptimeSeconds >= 0 and
        type(reading.load1) == "number" and reading.load1 >= 0 and
        type(reading.memoryTotalKb) == "number" and reading.memoryTotalKb > 0 and
        type(reading.memoryAvailableKb) == "number" and reading.memoryAvailableKb >= 0 and
        reading.memoryAvailableKb <= reading.memoryTotalKb then
        machine.status = "pass"
    end
else
    machine = {status="unavailable"}
end

local failed = false
for _, check in ipairs(checks) do
    if check.status ~= "pass" then failed = true end
end
print("EmberBSD board self-test v1")
for _, check in ipairs(checks) do
    print(string.format("check %s=%s exit=%s stderr_bytes=%d",
        check.name, check.status, tostring(check.exitCode or "-"), check.stderrBytes or 0))
    if check.output and check.output ~= "" then print("  " .. check.output:gsub("\n", "\n  ")) end
end
print(string.format("equipment=%s uptime_s=%s load1=%s memory_total_kib=%s memory_available_kib=%s temperatures=%d",
    machine.status, tostring(machine.uptimeSeconds or "-"), tostring(machine.load1 or "-"),
    tostring(machine.memoryTotalKiB or "-"), tostring(machine.memoryAvailableKiB or "-"),
    machine.temperatures and #machine.temperatures or 0))
local overall = failed and "fail" or (machine.status == "pass" and "pass" or "partial")
print("overall=" .. overall)
if failed then os.exit(1) end
