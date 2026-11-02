# Build

Spark uses C99, common Lua 5.5, libcurl with TLS, pthread, and dkjson 2.11.
NetBSD supplies SHA-256 through libc. macOS uses CommonCrypto.
Linux and FreeBSD use libcrypto.
NetBSD also supplies libprop and libbluetooth.

Use the common dependencies from [EmberBSD-Ports](https://github.com/oxtech-ember/EmberBSD-Ports) for EmberBSD targets.
OS headers, libc, and CRT must come from the matching EmberBSD SDK.
A host build does not qualify an EmberBSD package.

## Host build

Install the common Ports Lua 5.5 and dkjson 2.11 packages, plus libcurl with
TLS. The package uses the selected Lua interpreter, headers, and library
through pkg-config; it does not download or build a second Lua runtime. Set
`SPARK_DKJSON` to the installed common dkjson source file. On macOS, the
unconfigured default uses system curl; set `PKG_CONFIG` to the selected host
prefix pkg-config to link that prefix's libcurl and preserve its rpath.
Linux and FreeBSD also need libcrypto headers and libraries.
Use GNU Make 4+ or BSD make. macOS system make 3.81 is too old.
Select `gmake` on a host where `make` is an older implementation.

```sh
make
./build/agent-lua examples/hello.lua
```

The build creates `build/agent-lua` and `build/bluetooth-admin`.
Only NetBSD implements the Bluetooth administration backend.

For direct Makefile builds, set `LUA_PACKAGE` if pkg-config uses another Lua
package name. `build.sh` and the cross-build script use
`SPARK_LUA_PACKAGE` instead.
You can also supply the compiler and library flags:

```sh
make CC=gcc LUA_CFLAGS=-I/path/to/lua/include LUA_LIBS='-L/path/to/lua/lib -llua'
```

For dkjson outside the default module directories:

```sh
export LUA_PATH='/path/to/modules/?.lua;;'
```

## Host package

The package builder verifies the installed dkjson 2.11 source by SHA-256 and
uses the same common Lua 5.5 dependency as the target.

```sh
SPARK_DKJSON=/path/to/host-pkg-llvm/share/lua/5.5/dkjson.lua \
PKG_CONFIG=/path/to/host-pkg-llvm/bin/pkg-config \
SPARK_HOST_LUA=/path/to/host-pkg-llvm/bin/lua5.5 \
MAKE=/path/to/host-pkg-llvm/bin/gmake \
./build.sh --output-dir "$PWD/build/package" --version spark-development
./build/package/oxtorg-agent -capabilities
```

The output contains `oxtorg-agent`, `oxtorg-agent.lua`, `BUILD`,
and `runtime-dependencies.txt`. Lua is linked dynamically by default; the
dependency manifest records the selected host libraries.
The application and dkjson use lazy module loaders in one source file.
The executable finds that file beside itself, independent of the working directory.

The OS supplies curl, TLS libraries, and trusted certificate roots.
The builder records linked libraries. It does not make them portable across operating systems.
This script builds and executes host code. Use the [cross recipe](cross-build.md) for another target.

Builds do not run the full test suite. Use [the test commands](testing.md) explicitly.
