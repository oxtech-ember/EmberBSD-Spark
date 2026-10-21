-- A replaceable Lua tool; the native host does not know diagnostic codes.
return function(args)
    assert(type(args.code) == "string" and args.code:match("^%x%x%x%x$"), "code must contain four hex digits")
    local value = tonumber(args.code, 16)
    local system = ({"P", "C", "B", "U"})[(value >> 14) + 1]
    return system .. string.format("%04X", value & 0x3fff)
end
