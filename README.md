# EmberBSD-Spark

A small C99 and Lua 5.5 agent for intelligent devices.
Spark is an optional application in the [EmberBSD](https://github.com/oxtech-ember/EmberBSD) ecosystem.

C provides system operations. Lua implements task execution, model requests,
MCP, knowledge files, and tools. The device needs no Go or Python process.
The base OS does not depend on Spark, an AI provider, or a task service.

## Place in EmberBSD

Spark turns a request into calls to installed tools and tracks the task result.
It is an optional application for **Unix for intelligent devices**.
A phone, computer, or embedded node can select the parts its resources support.
Hardware, model execution, and graphical interfaces stay replaceable.

- [EmberBSD](https://github.com/oxtech-ember/EmberBSD#emberbsd-ecosystem) owns the OS, drivers, and image.
- [Ports](https://github.com/oxtech-ember/EmberBSD-Ports) owns shared dependencies and portability patches.
- [Prebuild SDK](https://github.com/oxtech-ember/EmberBSD-SDK) prepares cross-build tools and sysroots.
- [Runtime](https://github.com/oxtech-ember/EmberBSD-Runtime) designs device operations and application lifecycle contracts.
- [User-Skills](https://github.com/oxtech-ember/EmberBSD-User-Skills) describes device use and personal application changes.
- [Agent-Skills](https://github.com/oxtech-ember/Ember-Agent-Skills) describes shared development and porting.
- [DevBoards](https://github.com/oxtech-ember/EmberBSD-DevBoards) provides hardware references.
- [Examples](https://github.com/oxtech-ember/EmberBSD-Examples) provides independent demonstrations.

See [integration boundaries](docs/emberbsd.md) for skills, personal Ports,
GPU/NPU services, and the distinction between current code and planned contracts.

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

Install a C99 compiler, GNU Make 4+ or BSD make, pkg-config, Lua 5.5 development files,
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
- [EmberBSD integration](docs/emberbsd.md): ownership, workflows, and current boundaries.
- [Runtime](docs/runtime.md): configuration, state, protocols, and extensions.
- [NetBSD compatibility](docs/netbsd.md): system interfaces and existing service layouts.
- [Tests](docs/testing.md): existing fixture and package checks.
- [Contributing](CONTRIBUTING.md): interfaces, portability, and validation boundaries.

Protocol names `oxtorg-agent`, `OXTORG_*`, and `asenta.*` remain unchanged
for existing consumers. The project name is EmberBSD-Spark.

## License

New project code uses [BSD-2-Clause](LICENSE).
Imported dependencies retain their licenses. See [third-party notices](THIRD-PARTY.md).
