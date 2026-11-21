#!/bin/sh
# Exercise the real executable with a failing first libcurl initialization.
set -eu
host=$1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/spark-http.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
export SPARK_TEST_FAIL_FIRST_CURL_INIT=1

cat > "$tmp/offline.lua" <<'LUA'
assert(require("asenta.http").request)
io.write("offline")
LUA
"$host" "$tmp/offline.lua" > "$tmp/stdout" 2> "$tmp/stderr"
test "$(cat "$tmp/stdout")" = offline
test ! -s "$tmp/stderr"

cat > "$tmp/retry.lua" <<'LUA'
local http = require("asenta.http")
local invalid = {url = "http://"}
local ok, err = pcall(http.request, invalid)
assert(not ok and tostring(err):match("cannot initialize HTTP transport"))
-- curl rejects this URL locally. Both requests share the same easy handle.
for _ = 1, 2 do
    local code, message = http.request(invalid)
    assert(code == nil and type(message) == "string")
end
LUA
"$host" "$tmp/retry.lua" 2> "$tmp/stderr"
printf '%s\n' 'curl init' 'curl init' 'curl cleanup' > "$tmp/expected"
cmp "$tmp/expected" "$tmp/stderr"
