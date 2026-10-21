# Build

Spark uses C99, Lua 5.5, libcurl 7.85 or newer, pthread, and dkjson.
NetBSD supplies SHA-256 through libc. macOS uses CommonCrypto.
Linux and FreeBSD use libcrypto.
NetBSD also supplies libprop and libbluetooth.

Use the common dependencies from [EmberBSD-Ports](https://github.com/oxtech-ember/EmberBSD-Ports) for EmberBSD targets.
OS headers, libc, and CRT must come from the matching EmberBSD SDK.
A host build does not qualify an EmberBSD package.

## Host build

Install Lua 5.5 headers and libraries, libcurl with TLS, and dkjson.
Linux and FreeBSD also need libcrypto headers and libraries.
Use GNU Make 4+ or BSD make. macOS system make 3.81 is too old.
Select `gmake` on a host where `make` is an older implementation.

```sh
make
./build/agent-lua examples/hello.lua
```

The build creates `build/agent-lua` and `build/bluetooth-admin`.
Only NetBSD implements the Bluetooth administration backend.

If pkg-config uses another Lua package name, set `LUA_PACKAGE`.
You can also supply the compiler and library flags:

```sh
make CC=gcc LUA_CFLAGS=-I/path/to/lua/include LUA_LIBS='-L/path/to/lua/lib -llua'
```

For dkjson outside the default module directories:

```sh
export LUA_PATH='/path/to/modules/?.lua;;'
```

## Portable host bundle

The bundle builder uses Lua 5.5.1 and dkjson 2.11.
It uses the same Lua minor version as the common EmberBSD dependency.
Rebuild native Lua modules for this ABI; do not load Lua 5.4 modules.
The script verifies both downloads by SHA-256.

```sh
MAKE=make ./build.sh --output-dir "$PWD/build/package" --version spark-development
./build/package/oxtorg-agent -capabilities
```

Use `--inputs DIR` for cached, verified inputs.
The output contains `oxtorg-agent`, `oxtorg-agent.lua`, `BUILD`,
and `runtime-dependencies.txt`. Lua is linked statically.
The application and dkjson use lazy module loaders in one source file.
The executable finds that file beside itself, independent of the working directory.

The OS supplies curl, TLS libraries, and trusted certificate roots.
The builder records linked libraries. It does not make them portable across operating systems.
This script builds and executes host code. Use the [cross recipe](cross-build.md) for another target.

Builds do not run the full test suite. Use [the test commands](testing.md) explicitly.
