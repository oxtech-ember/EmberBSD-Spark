# EmberBSD-Spark

A small C99 and Lua 5.4 agent for intelligent devices.
Spark is an optional application in the [EmberBSD](https://github.com/oxtech-ember/EmberBSD) ecosystem.

C provides system operations. Lua implements task execution, model requests,
MCP, knowledge files, and tools. The device needs no Go or Python process.
The base OS does not depend on Spark, an AI provider, or a task service.

## Current scope

- Execute tasks from a compatible task server and resume interrupted attempts.
- Call a Responses-compatible model endpoint and account for reported usage.
- Use MCP tools, local Lua tools, text skills, and a tool workshop.
- Read equipment metrics and use the Bluetooth and ELM327 C adapters.

The current task loop requires a compatible server. That server is not included.
The local test fixture runs without a private service or model account.
Browser control, PDF reading, full subagent profiles, and arbitrary background
programs are not implemented by this small profile.

## Build and try

Install a C99 compiler, make, pkg-config, Lua 5.4 development files,
libcurl 7.85 or newer with TLS, and dkjson.
Linux and FreeBSD also need libcrypto development files.

```sh
git clone https://github.com/oxtech-ember/EmberBSD-Spark.git
cd EmberBSD-Spark
make
./build/agent-lua examples/hello.lua
```

This local example needs no server or credentials.
See [build instructions](docs/build.md) for host packages and the portable bundle.
For an EmberBSD target, use the shared GCC16 compiler and SDK/Ports dependencies.
See [cross builds](docs/cross-build.md). Do not build development tools on the device.

## Documentation

- [Build](docs/build.md): host builds, dependencies, and packaging.
- [Cross build](docs/cross-build.md): GCC16, target libraries, and source modules.
- [Runtime](docs/runtime.md): configuration, state, protocols, and extensions.
- [NetBSD compatibility](docs/netbsd.md): system interfaces and existing service layouts.
- [Tests](docs/testing.md): existing fixture and package checks.
- [Contributing](CONTRIBUTING.md): interfaces, portability, and validation boundaries.

Protocol names `oxtorg-agent`, `OXTORG_*`, and `asenta.*` remain unchanged
for existing consumers. The project name is EmberBSD-Spark.

## License

New project code uses [BSD-2-Clause](LICENSE).
Imported dependencies retain their licenses. See [third-party notices](THIRD-PARTY.md).
