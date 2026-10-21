# Tests

Go is a host-side test dependency. The device runs C and Lua only.
The fixture creates local HTTPS services, subprocesses, and temporary files.
It needs no private repository, deployed server, or model account.

## Full suite

```sh
make CC=gcc test
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
