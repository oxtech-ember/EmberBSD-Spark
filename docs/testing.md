# Tests

Go is a host-side test dependency. The device runs C and Lua only.
The fixture creates local HTTPS services, subprocesses, and temporary files.
It needs no private repository, deployed server, or model account.

## Full suite

```sh
CC=gcc make CC=gcc test
```

Install the `lua5.5` interpreter for workshop process checks.
`CC` also selects compilers for native test helpers.

The full suite covers MCP, knowledge, tools, task recovery, and native boundaries.
It is separate from compilation and deployment.
Set `GO_AGENT` only for an optional comparison with a compatible external executable.

## Package relocation

```sh
./build.sh --output-dir "$PWD/build/package" --version spark-test
cd tests
OXTORG_NATIVE_AGENT_BUNDLE="$PWD/../build/package" \
  go test -count=1 -timeout=60s -run '^TestNativePackageRelocation$' .
```

The test relocates the bundle and completes a task through local HTTPS fixtures.
It does not read Lua modules from the original checkout.

## Target checks

Cross-compile the Go test executable on the host if the target has no Go compiler.
Use the correct `GOOS` and `GOARCH` for that target.
Transfer `tests/`, including `testdata/`, `lua/`, `examples/`, `emberbsd/`,
and the required `build/` executables. Keep the repository layout.

Run the test executable from `tests/` with the target's dkjson module path.
Do not run host binaries or host Lua bytecode on the target.
Report compilation, fixture execution, device behavior, and long-run results separately.

## Extended host checks

Build the portable bundle first. Compile a separate set of Lua modules:

```sh
mkdir -p build/compiled
build/agent-lua compile.lua build/compiled lua/*.lua
cd tests
CC=gcc \
OXTORG_COMPILED_LUA_DIR="$PWD/../build/compiled" \
OXTORG_SHARED_LIBC_TEST_HOST="$PWD/../build/package/oxtorg-agent" \
OXTORG_NATIVE_AGENT_BUNDLE="$PWD/../build/package" \
  go test -count=1 .
```

Keep dkjson on the Lua module search path for both processes and compiled modules.
A custom `LUA_PATH` must use a module template such as `/path/to/modules/?.lua;;`.
A literal dkjson filename would shadow unrelated source and native modules.
`GO_AGENT` remains an optional comparison with an external implementation.

## Validation scope

The control build uses GCC 16.2.0, Lua 5.5.1, dkjson 2.11, and Go 1.27.2 on macOS arm64.
Both the dynamic host executable and the static-Lua bundle compile.
The full extended host suite passes 75 tests. Only the optional external Go-agent comparison is skipped.
Coverage includes HTTPS task flow, recovery, MCP, Lua workshop, bytecode, native modules, and package relocation.
Bluetooth and equipment tests use local fixtures; they do not exercise a real adapter or sensor.
The Lua 5.5 state constructor uses the seed required by its
[public API](https://www.lua.org/manual/5.5/manual.html#lua_newstate).
The [seed helper](https://www.lua.org/manual/5.5/manual.html#luaL_makeseed) accepts a null state.

Cppcheck 2.22.0 covers all nine C files with the host compilation arguments,
C99, `unix64`, and warning, style, performance, and portability checks.
The extracted baseline and this integration have the same 25 findings: 23 style and two warnings.
No categories are disabled. This is a comparison, not a zero-finding analysis.
The two equipment warnings concern the bounded temperature-name index and `qsort` with zero entries.
The insertion/restore bounds and zero-count call explain these false positives.
The remaining style findings stay with the source modules; they are not new regressions.
GCC 16.2.0 `-fanalyzer` and Apple Clang 21.0.0 Static Analyzer report no findings in changed `src/main.c`.
Clang is used only for analysis.

GCC ASan/UBSan checks Lua state creation, allocation, repeated GC, and shutdown.
The check uses `-fsanitize=address,undefined`, `halt_on_error=1`, and `detect_leaks=1`.
It reports no memory error, but macOS dyld module-map warnings limit sanitizer backtraces.
The system Lua library is not instrumented. This is not a Valgrind run or a complete leak qualification.

These checks do not qualify an EmberBSD binary.
The available target sysroot contains Lua 5.4.6; the GCC16 dependency check rejects ABI 504.
Build with the common Lua 5.5 sysroot before target tests. Do not add a legacy Lua fallback.
Device I/O, a real model service, and a long-run installation require separate acceptance.

Reproduce the focused memory check with the selected GCC and Lua dependency:

```sh
make CC=gcc BUILD_DIR=build/asan \
  CFLAGS='-O1 -g -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer' \
  LDFLAGS='-fsanitize=address,undefined' all
ASAN_OPTIONS=halt_on_error=1:detect_leaks=1 \
UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
  build/asan/agent-lua tests/testdata/allocator.lua
```
