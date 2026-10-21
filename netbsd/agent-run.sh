#!/bin/sh
# Load installation settings once, then replace the shell with the agent.
trap '' HUP
set -a
. /etc/oxtorg/agent.env
set +a
[ -n "${OXTORG_TOKEN:-}" ] || exit 0
PATH=/opt/oxtorg/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/pkg/sbin:/usr/pkg/bin
HOME=/var/lib/oxtorg-agent
OXTORG_MCP=/var/lib/oxtorg-agent
OXTORG_AGENT_PIDFILE=/var/run/oxtorg/agent.pid
OXTORG_AGENT_SYSLOG=1
export PATH HOME OXTORG_MCP OXTORG_AGENT_PIDFILE OXTORG_AGENT_SYSLOG
cd /opt/oxtorg/roles/equipment-watch || exit 1
set --
[ -z "${OXTORG_SERVER:-}" ] || set -- --server "$OXTORG_SERVER"
exec /opt/oxtorg/bin/oxtorg-agent "$@" \
        --config /opt/oxtorg/roles/equipment-watch/agent.json \
        --state-root "${OXTORG_LUA_STATE_ROOT:-/var/lib/oxtorg-agent/c-lua}" \
        --program-dir /opt/oxtorg/bin
