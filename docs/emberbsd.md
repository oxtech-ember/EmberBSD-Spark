# Spark in EmberBSD

EmberBSD is Unix for intelligent devices.
Spark is one optional application that uses its processes, files, network,
permissions, and device interfaces. The base OS works without Spark.
An installed model, task server, and graphical shell are separate choices.

## Responsibilities

C implements the local system adapters. Lua implements agent policy and task flow.
Model and MCP adapters connect the application to selected services.
Keep provider details outside OS code and shared hardware contracts.

[OS](https://github.com/oxtech-ember/EmberBSD) fixes belong in the OS repository.
Shared dependencies belong in [Ports](https://github.com/oxtech-ember/EmberBSD-Ports).
[Prebuild SDK](https://github.com/oxtech-ember/EmberBSD-SDK) prepares the host toolchain and sysroot.
Spark builds with the common GCC16 and Lua 5.5 dependency set.
A target device executes completed programs; it need not build the development tools.

[Runtime](https://github.com/oxtech-ember/EmberBSD-Runtime) owns the planned device API and application lifecycle.
Spark is its intended client, not a second implementation of that contract.
The current C adapters use existing system interfaces directly.
No released Runtime API is required or claimed by this repository.
Future adapters must preserve capability discovery, errors, cancellation, and permissions.

## Skills and personal changes

[User-Skills](https://github.com/oxtech-ember/EmberBSD-User-Skills) covers installation,
diagnostics, application management, and personal Ports.
[Agent-Skills](https://github.com/oxtech-ember/Ember-Agent-Skills) covers shared development and porting.
Both packages are instructions. Spark supplies executable agent behavior.

A request can describe a new button, a smaller interface, or changed program behavior.
The intended workflow edits available source, builds on a development host,
checks the requested behavior, and retains the patch in the selected personal Ports repository.
Upstream supplies new source releases; the personal repository supplies the retained change.
A general source-editing or GitHub workflow is not yet an accepted Spark feature.
Its existing task protocol can deliver skill text. It does not install the Codex plugin packages.
The installation must provide tools, credentials, and permissions for each workflow.

## Models, GPU, NPU, and devices

The current model adapter calls a Responses-compatible HTTP endpoint.
A local or remote service must implement the protocol this adapter expects.
An OpenAI-compatible label alone does not establish that compatibility.
Spark does not link an inference engine or select a GPU/NPU driver.
Acceleration belongs to the selected inference service and the OS/Ports hardware stack.

[DevBoards](https://github.com/oxtech-ember/EmberBSD-DevBoards) supplies hardware references.
[Examples](https://github.com/oxtech-ember/EmberBSD-Examples) supplies independently testable applications.
The equipment, Bluetooth, and ELM327 adapters expose a limited current device surface.
Host fixtures do not prove radio, vehicle, or sensor behavior on a physical board.

A shared dispatcher is a planned integration boundary.
The current task loop uses an external compatible server and runs one task per process.
This repository does not implement fleet placement or migration of a running process.

## Compatibility and verification

Keep existing `oxtorg-agent`, `OXTORG_*`, and `asenta.*` identifiers where consumers require them.
They are protocol and installation compatibility names, not OS dependencies.
New public examples must work without private configuration or a particular deployed service.
See [runtime](runtime.md), [tests](testing.md), and [cross-build](cross-build.md).
