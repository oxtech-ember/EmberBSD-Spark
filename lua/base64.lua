local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Encode a byte string. Stream callers use blocks divisible by three so
-- padding occurs only at the end of the input.
return function(bytes)
    local encoded = {}
    for i = 1, #bytes, 3 do
        local a, b, c = bytes:byte(i, i + 2)
        local n = (a << 16) | ((b or 0) << 8) | (c or 0)
        encoded[#encoded + 1] = alphabet:sub((n >> 18) + 1, (n >> 18) + 1) ..
            alphabet:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1) ..
            (b and alphabet:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) or "=") ..
            (c and alphabet:sub((n & 63) + 1, (n & 63) + 1) or "=")
    end
    return table.concat(encoded)
end
