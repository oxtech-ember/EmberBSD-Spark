#!/bin/sh
# Install the built application into an existing EmberBSD equipment installation.
# Install the prebuilt native payload; source files remain on the build host.
set -eu
PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH
source_dir=$(CDPATH= cd -- "${1:?Usage: install.sh SOURCE_DIR BUILD_ID PAYLOAD_DIR}" && pwd)
build_id=${2:?Build identifier is required}
prefix=/opt/oxtorg/experiments/agent-lua
payload=$(CDPATH= cd -- "${3:?prebuilt payload directory is required}" && pwd)
test -x "$payload/bin/agent-lua"
test -x "$payload/bin/bluetooth-admin"
test -r "$payload/lua/serve.lua"
test -r "$payload/lua/dkjson.lua"
test -r "$payload/runtime-dependencies.txt"
config=/opt/oxtorg/roles/equipment-watch/agent.json
config_owner=$(stat -f %Su "$config")
config_group=$(stat -f %Sg "$config")
config_mode=$(stat -f %Lp "$config")
# Prepare configuration before stopping the working service.
LUA_PATH="$payload/lua/?.lua;;" "$payload/bin/agent-lua" \
    "$payload/emberbsd/native-config.lua" "$payload/lua" "$config"
chown "$config_owner:$config_group" "$config.native"
chmod "$config_mode" "$config.native"

if /etc/rc.d/oxtorg_agent status >/dev/null 2>&1; then
    /etc/rc.d/oxtorg_agent stop
fi
if [ -x /etc/rc.d/oxtorg_bluetooth_agent ] && /etc/rc.d/oxtorg_bluetooth_agent status >/dev/null 2>&1; then
    /etc/rc.d/oxtorg_bluetooth_agent stop
fi
# Stop the installed service with its existing rc.d before retiring its runner.
attempts=0
while pgrep -f '^/opt/oxtorg/(experiments/agent-lua/bin/(agent-supervisor|agent-lua)([[:space:]]|$)|bin/oxtorg-bluetooth-broker([[:space:]]|$))' >/dev/null; do
    [ "$attempts" -lt 30 ] || { echo 'application processes remain; no payload was replaced' >&2; exit 1; }
    sleep 1; attempts=$((attempts + 1))
done
install -d -o root -g wheel -m 755 "$prefix/bin" "$prefix/lua"
install -o root -g wheel -m 755 "$payload/bin/agent-lua" "$prefix/bin/agent-lua.new"
mv "$prefix/bin/agent-lua.new" "$prefix/bin/agent-lua"
rm -f "$prefix/bin/agent-supervisor" "$prefix/bin/bluetooth-broker" "$prefix/lua/bluetooth_broker.lua"
install -o root -g wheel -m 755 "$payload/emberbsd/agent-rc" /etc/rc.d/oxtorg_agent
rm -rf "$prefix/lua"
install -d -o root -g wheel -m 755 "$prefix/lua"
install -o root -g wheel -m 644 "$payload/lua/"*.lua "$prefix/lua/"
rm -rf "$prefix/deps"
install -o root -g wheel -m 644 "$payload/runtime-dependencies.txt" "$prefix/runtime-dependencies.txt"
install -o root -g wheel -m 644 "$source_dir/README.md" "$prefix/README.md"
printf '%s\n' "$build_id" >"$prefix/BUILD"
chmod 644 "$prefix/BUILD"
install -o root -g wheel -m 755 "$payload/emberbsd/agent.sh" /opt/oxtorg/bin/oxtorg-agent.new
mv /opt/oxtorg/bin/oxtorg-agent.new /opt/oxtorg/bin/oxtorg-agent
install -o root -g wheel -m 755 "$payload/emberbsd/agent-run.sh" /opt/oxtorg/bin/oxtorg-agent-run.new
mv /opt/oxtorg/bin/oxtorg-agent-run.new /opt/oxtorg/bin/oxtorg-agent-run
install -o root -g oxtorg -m 4750 "$payload/bin/bluetooth-admin" /opt/oxtorg/bin/oxtorg-bluetooth-admin.new
mv /opt/oxtorg/bin/oxtorg-bluetooth-admin.new /opt/oxtorg/bin/oxtorg-bluetooth-admin
# The agent owns the Bluetooth session; only fixed administrative actions elevate.
rm -f /opt/oxtorg/bin/oxtorg-bluetooth-broker /etc/rc.d/oxtorg_bluetooth_agent \
    /var/run/oxtorg-bluetooth-agent.pid /var/run/oxtorg-bluetooth/control.sock
rmdir /var/run/oxtorg-bluetooth 2>/dev/null || true
cp -p /etc/rc.conf /etc/rc.conf.new
sed '/^[[:space:]]*oxtorg_bluetooth_agent=/d' /etc/rc.conf > /etc/rc.conf.new
mv /etc/rc.conf.new /etc/rc.conf
mv "$config.native" "$config"
/etc/rc.d/oxtorg_agent start
