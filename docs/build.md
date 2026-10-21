# Build

Spark uses C99, Lua 5.4, libcurl 7.85 or newer, pthread, and dkjson.
NetBSD supplies SHA-256 through libc. macOS uses CommonCrypto.
Linux and FreeBSD use libcrypto.
NetBSD also supplies libprop and libbluetooth.

Use the common dependencies from [EmberBSD-Ports](https://github.com/oxtech-ember/EmberBSD-Ports) for EmberBSD targets.
OS headers, libc, and CRT must come from the matching EmberBSD SDK.
A host build does not qualify an EmberBSD package.

## Host build

On a Debian-family development host, install the development packages:

```sh
sudo apt-get install build-essential pkg-config liblua5.4-dev lua-dkjson libcurl4-openssl-dev libssl-dev
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

The existing bundle builder uses Lua 5.4.8 and dkjson 2.11.
These pins preserve the current application ABI and package format.
The script verifies both downloads by SHA-256.

```sh
./build.sh --output-dir "$PWD/build/package" --version spark-development
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
