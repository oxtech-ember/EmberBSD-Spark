# Third-party dependencies

Lua and dkjson come from the selected common Ports dependency set. The package
builder verifies the installed dkjson 2.11 source before embedding it.

| Component | License | Use |
| --- | --- | --- |
| [Lua 5.5.1](https://www.lua.org/license.html) | MIT | Common Ports dependency; linked to the application |
| [dkjson 2.11](https://dkolf.de/dkjson-lua/) | MIT | Included in the Lua application |
| [curl](https://curl.se/docs/copyright.html) | curl license | Provided by the selected host or target dependency set |

Linux and FreeBSD also use libcrypto.
NetBSD uses libc for SHA-256. macOS uses CommonCrypto.
Their licenses follow the selected system or dependency package.

The package includes this file with the Lua notice. The dkjson license remains
in `oxtorg-agent.lua`.

Copyright (C) 1994-2026 Lua.org, PUC-Rio.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
Cross-build dependencies belong to the common Ports/SDK input set.
Preserve their notices when distributing a complete device image.
