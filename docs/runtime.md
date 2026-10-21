# Runtime and extensions

## Configuration

Use `examples/agent.json` as the configuration template.
Set the task server, model endpoint, and model alias for your installation.
The example addresses are placeholders. Keys come from the named environment variables.
The server implementation and model service are separate dependencies.

The model adapter uses `/v1/responses` and reads model pricing metadata.
It does not implement every provider's API. `model.via=server` routes model calls through the task server.
The server protocol includes task leases, events, attachments, budgets, and shared knowledge.
MCP uses the common tool registry. Local policy stays in Lua.

Role files and relative paths resolve from the configuration directory.
A single task and the queue use the same application modules:

```sh
./build/agent-lua lua/run.lua /path/to/agent.json TASK_ID /path/to/state /path/to/programs
./build/agent-lua lua/serve.lua --config /path/to/agent.json \
  --state-root /path/to/state --program-dir /path/to/programs
```

`--once` runs one queue pass. `--server` overrides the configured server.
Only one task runs at a time in each agent process.
The program directory contains external MCP programs and their declarations.

The portable bundle accepts `-config`, `-server`, `-version`,
`-capabilities`, `-lang`, and `-accept-tools ALIAS`.
Both short and double-dash forms are supported where the parser declares them.
`-lang` selects an adjacent role translation. Built-in messages are English.
`-accept-tools` accepts pending MCP declarations without a model request.

## State and process lifecycle

Set state through `--state-root`, `OXTORG_LUA_STATE_ROOT`, or `stateRoot`.
The fallback is `OXTORG_MCP/native-state`.
State is separated by endpoint, organization, and executor.
The active attempt records its context, revision, and pending operation.

A paid request or an action with an unknown outcome is not replayed automatically.
Event and attachment retries reuse the saved identity and bytes.
Old private queues and unpublished drafts are not imported automatically.

Knowledge snapshots, history, model input, role text, and tool schemas use files.
This reduces resident memory. Large individual responses and TLS still affect the peak.
The MCP description page is currently decoded as one value.
A hook that asks for all records can also materialize them.

`transport.maxBytes` sets the response limit.
`historyMaxBytes` can set a separate history limit.
Without a configured response limit, the current default is 32 MiB.

`OXTORG_SUPERVISED=1` enables commands from stdin.
`drain` completes the active attempt and stops the next attempt.
EOF is detected between attempts and during queue waits.
EOF does not interrupt a blocked operation inside an attempt.
SIGTERM stops the agent and its child processes.
A later start resumes the saved attempt.

## Native adapters and Lua tools

Native modules are `asenta.core`, `asenta.http`, `asenta.fs`,
`asenta.process`, `asenta.equipment`, `asenta.bluetooth`, and `asenta.obd`.
Their interface version is `asenta.core.apiVersion`.

A local MCP configuration can select an in-process module:

```json
{"mcp":[
  {"alias":"equipment","module":"equipment",
   "args":["-collect-interval","5s","-collect-history","1000"],
   "envFrom":{"EQUIPMENT_UNITS":"EQUIPMENT_UNITS"}},
  {"alias":"bluetooth","module":"bluetooth"}
]}
```

External MCP services use `command` or `url`.
Server-selected aliases refer to locally configured adapters.
They do not select arbitrary native modules.

`luaTools` loads a trusted file that returns `function(args)`.
A `config.modules` module exports `install(context)`.
A registry entry has `name`, `description`, `parameters`, `class`, and `invoke`.
The current classes are `read`, `write_local`, `exec`, `attended`, `external`, and `physical`.

Mutator modules return `name`, `digest`, and `hooks`.
Supported hooks are `BeforeTurn`, `BeforeTool`, `AfterTool`, and `Call`.
Trusted modules have the main process's access.
Workshop-created Lua tools execute in separate processes.
The default interpreter is `lua5.5` from the installation PATH.
Set `workshop.lua` to an explicit Lua 5.5 executable path when needed.
The child receives the installed dkjson module path.
The portable bundle includes Lua in the agent process; it does not install
this separate workshop interpreter.

An MCP module exports `connect(spec, options)`.
The connection provides `tools()`, `report()`, and `close()`.
Options include the permitted environment, state root, and declaration root.
Standard `require` can load installation-owned native modules in supported builds.

The host is synchronous. Parallel I/O requires a different adapter.
The small profile does not implement the complete subagent or browser stack.
`lua/main.lua` and `lua/agent.lua` retain the early protocol fixture.
Production queue execution uses `serve.lua`.
