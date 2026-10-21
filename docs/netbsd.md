# NetBSD interfaces and existing service layouts

EmberBSD retains the NetBSD ABI and platform identifiers where required.
Spark uses those interfaces for libc, libprop, Bluetooth, process state, and syslog.
The target OS is EmberBSD. Do not substitute upstream NetBSD headers or libc in its sysroot.

Build target programs on the development host with the common GCC16 toolchain.
Use the [cross-build instructions](cross-build.md).
Deploy completed programs to a VM or board for execution checks.

## Compatibility scripts

The files in `netbsd/` preserve an existing service layout.
They are integration helpers, not a complete device installer.
They expect the following installation-owned inputs:

- The `oxtorg` user and group.
- Configuration and role files under `/opt/oxtorg/roles/equipment-watch/`.
- Credentials in `/etc/oxtorg/agent.env`.
- A prepared payload with `bin/`, `lua/`, `netbsd/`, and dependency notices.

`netbsd/install.sh` replaces that service and its payload.
It does not create the server, account, role, or credentials.
Review its fixed paths before using it with another installation.
The server address comes from the configuration file.
`OXTORG_SERVER` can override it.

The service holds a PID-file lock and writes to syslog.
A crash requires an explicit service restart.
The state default is `/var/lib/oxtorg-agent/c-lua`.

## Bluetooth

The agent owns Bluetooth sessions.
A short C helper performs privileged administrative operations.
Its supported operations are `state`, `power on|off`,
and `pair MAC bonded|just-works|legacy-pin`.

The compatibility installer gives the helper owner `root:oxtorg` and mode `4750`.
PINs come from the installation's root-owned `/etc/oxtorg/bluetooth-pins.json`.
They do not appear in process arguments or agent memory.
The agent closes its sessions on exit.
Physical pairing, audio, and ELM327 behavior need separate device checks.

The extracted source retains NetBSD/ARM64 and RV32 code paths.
A successful host test does not verify a current EmberBSD board or sysroot.
