# Third-party dependencies

The host bundle builder downloads these pinned sources and checks their SHA-256 values.

| Component | License | Use |
| --- | --- | --- |
| [Lua 5.5.1](https://www.lua.org/license.html) | MIT | Statically linked in the host bundle |
| [dkjson 2.11](https://dkolf.de/dkjson-lua/) | MIT | Included in the Lua application |
| [curl](https://curl.se/docs/copyright.html) | curl license | Provided by the selected host or target dependency set |

Linux and FreeBSD also use libcrypto.
NetBSD uses libc for SHA-256. macOS uses CommonCrypto.
Their licenses follow the selected system or dependency package.

The bundle records linked libraries and Lua's notice in `runtime-dependencies.txt`.
The dkjson source keeps its license in `oxtorg-agent.lua`.
Cross-build dependencies belong to the common Ports/SDK input set.
Preserve their notices when distributing a complete device image.
