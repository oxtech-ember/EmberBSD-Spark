#!/bin/sh
# The host and application are updated together; site settings stay separate.
prefix=${OXTORG_AGENT_LUA_HOME:-/opt/oxtorg/experiments/agent-lua}
LUA_PATH="$prefix/lua/?.lua;${LUA_PATH:-;}"
# The board favors promptly returning unused pages over allocator throughput.
# An installation can still supply its own allocator policy.
MALLOC_CONF=${MALLOC_CONF:-narenas:1,dirty_decay_ms:0,muzzy_decay_ms:0,tcache:false}
if [ -r "$prefix/BUILD" ]; then
    OXTORG_AGENT_BUILD=$(cat "$prefix/BUILD")
    export OXTORG_AGENT_BUILD
fi
export LUA_PATH MALLOC_CONF
exec "$prefix/bin/agent-lua" "$prefix/lua/serve.lua" "$@"
