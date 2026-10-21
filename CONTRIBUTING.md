# Contributing

Spark is an optional application. Keep OS mechanisms separate from application policy.
Use POSIX/BSD interfaces and documented protocols.
Keep provider-specific behavior in adapters.

Write code, comments, documentation, and commit messages in English.
Use short active sentences and exact CLI or API names.
Keep each documentation file below 250 lines. Split independent topics.
Use NetBSD KNF for new C code.

Preserve existing protocol identifiers and explain interface changes.
Keep C system modules separate from Lua application logic.
Do not add a required Go or Python process on the device.

Use the shared GCC16 compiler and current Ports dependencies for EmberBSD targets.
Keep the target compiler, ABI, sysroot, and dependency provenance consistent.
Build on the development host. Use devices and VMs for execution checks.
Dependency and OS fixes belong in their owning repositories.

Choose checks that exercise the change.
Run Cppcheck with the actual build flags for C changes.
Use GCC analysis and Clang Static Analyzer for affected paths.
Clang is an analysis tool, not the EmberBSD target compiler.
Use Valgrind Memcheck on a supported host, or name the sanitizer used instead.
A clean host check does not prove device or long-run behavior.

Run tests separately from compilation and deployment.
State the checked commit, commands, results, and important limitations.
Preserve third-party licenses and source attribution.
Disclose AI-assisted changes in the commit or contribution description.

Do not commit credentials, local service configuration, logs, or device images.
Examples must run without private projects or hidden local files.
