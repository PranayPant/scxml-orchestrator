# scxml_orchestrator

An Elixir/BEAM runtime for the **UI AST Runtime** architecture: it ingests a
statechart **AST JSON document** (as emitted by the companion
[`scxml-parser`](https://github.com/PranayPant/web-scxml-editor) project),
compiles it into an immutable, pre-computed **RuntimeGraph**, and executes the
statechart through a macrostep/microstep interpreter.

The runtime is fully decoupled from the visual editor and the SCXML parser:
the canonical document is a plain JSON AST, and the compiler/engine consume
that AST directly (no canonical re-normalization layer).

```
 AST JSON (from scxml-parser)  ──►  ScxmlEngine.Compiler ──► RuntimeGraph
                                                                 │
                                   stored in :persistent_term  │
                                                                 ▼
                        ScxmlEngine.Instance (GenServer) ──► macrostep/microstep
                        • mailbox = external event queue          interpreter
                        • active configuration (MapSet)
                        • datamodel + internal queue
```

## Input contract

The orchestrator consumes the **parser's actual AST spec** — a JSON document
shaped like the TypeScript `SCXMLDocument` produced by `scxml-parser`:

```json
{
  "scxml": {
    "id": "traffic",
    "initial": "red",
    "states": [
      {
        "id": "red",
        "type": "atomic",
        "transitions": [
          { "id": "t1", "event": "next", "target": "green", "executable": [] }
        ],
        "metadata": []
      }
    ],
    "parallels": [],
    "finals": []
  }
}
```

Notable conventions the compiler handles:

- **Nested arrays** — states live in `states[]` / `parallels[]` / `finals[]` /
  `history[]` arrays (per node); the compiler folds them into flat maps keyed
  by id during compilation.
- **Lowercase action keys** — `onentry` / `onexit`, and `transition.executable`
  (a `kind`-discriminated list, e.g. `raise`, `assign`, `log`, `if`).
- **Space-separated, possibly dotted targets** — `target: "both.audio both.video"`
  resolves dotted hierarchical paths (`both.audio` → `audio`) through the
  parent map; multiple targets enter several parallel regions concurrently.
- **Layout** lives opaquely in `metadata` blocks and is ignored by the runtime.

## Usage

```elixir
# 1. Load + compile + store the graph, and start an instance in one call:
ast_json = File.read!("test/fixtures/traffic_light.json")
{:ok, pid} = ScxmlEngine.run(ast_json, instance_id: "traffic_1")

# 2. Drive it with events (synchronous "step" semantics — returns once the
#    macrostep has fully settled):
ScxmlEngine.send_event(pid, "next")

# 3. Inspect state:
ScxmlEngine.active_configuration(pid)  # MapSet of active state ids
ScxmlEngine.datamodel(pid)
ScxmlEngine.done?(pid)

# 4. Look up / route by instance id:
ScxmlEngine.instance_pid("traffic_1")
ScxmlEngine.send_event_to("traffic_1", "next")
ScxmlEngine.instances()               # [{instance_id, pid}, ...]
```

### Lower-level API

| Function                       | Purpose                                                              |
| ------------------------------ | -------------------------------------------------------------------- |
| `ScxmlEngine.load/1`           | Parse a parser-AST JSON string into a raw `RuntimeGraph`.            |
| `ScxmlEngine.store/2`          | Compile + store the graph in `:persistent_term`; returns `graph_id`. |
| `ScxmlEngine.start_instance/1` | Spawn an instance for an already-stored graph.                       |
| `ScxmlEngine.run/2`            | `load` + `store` + `start_instance` in one step.                     |

## Architecture

The project follows `ARCHITECTURE.md`:

- **`ScxmlEngine.Compiler`** — pure-functional transform (no process side
  effects). Builds `parent_map`, `ancestors_map`, and an `event_index`, and
  pre-computes each transition's LCA `exit_set` / `entry_set` (UI-AST-RUNTIME
  §4). Compiled graphs are stored in `:persistent_term` keyed
  `{:scxml_graph, graph_id}` so millions of instances read them zero-copy.
- **`ScxmlEngine.EventMatcher`** — wildcard (`*`), dot-prefix (`user.*`),
  tokenized (`"A B"`), and exact event matching.
- **`ScxmlEngine.Expression`** — a **sandboxed** guard/expression evaluator
  over the datamodel (arithmetic, comparison, boolean, map path access).
  `Code.eval_string/2` is deliberately avoided (RCE risk from untrusted SCXML).
- **`ScxmlEngine.Instance`** — a `GenServer` per running statechart. The
  mailbox is the external queue; process state holds the active configuration
  (`MapSet`), the datamodel, and the internal queue. Implements the
  macrostep/microstep interpreter: exit bottom-up → transition actions →
  enter top-down (with compound/parallel default-entry expansion) →
  settle eventless transitions.
- **`ScxmlEngine.Registry` + `ScxmlEngine.Instances`** — an OTP
  `Registry` mapping `instance_id` → pid, plus a `DynamicSupervisor` that
  spawns/isolates instances on demand.

## Tests

```sh
mix test
```

The suite covers deserialization, the event matcher, the LCA compiler, the
expression evaluator, and full macrostep integrations (parallel regions,
history, guards, eventless settling) using fixtures in `test/fixtures/`.

## CLI sandbox (escript)

A small console entrypoint — `ScxmlOrchestrator.Main` — packages the engine
into a single executable (`escript`) so you can poke at statecharts from the
shell without writing any Elixir. It is intentionally a **playground**, not a
production interface; production consumption happens through the library API.

Build it (requires a local Elixir/Mix toolchain):

```sh
mix escript.build
```

Run it — the resulting binary needs **only Erlang** at runtime:

```sh
./scxml_orchestrator --file test/fixtures/traffic_light.json --event next
# > event: next
#   active_configuration: ["green"]
#   datamodel: %{"_event" => ..., "data" => %{"color" => "green"}}
#   done? false
```

Options:

| Flag            | Description                                                    |
| --------------- | -------------------------------------------------------------- |
| `--file <path>` | Path to the SCXML AST JSON document (required).                |
| `--event <n>`   | Dispatch an event (repeat for multiple, in order).             |
| `--datamodel`   | Initial datamodel as a JSON object, e.g. `'{"speed": 3}'`.     |
| `--instance-id` | Instance id to register under (defaults to the graph id).      |
| `--help`        | Show usage.                                                    |

Exit codes: `0` success, `2` bad usage, `3` could not load/run the document,
`4` event dispatch failed. On Windows, invoke it via the escript runner, e.g.
`escript .\scxml_orchestrator --file ...`.

## Docker (deps-free testing)

The included `Dockerfile` lets you run the full build/test/lint toolchain with
**zero local Elixir/Mix/deps installed** — it is not a distribution vehicle
for the library or the CLI. Build and run:

```sh
docker build -t scxml-orchestrator .
docker run --rm scxml-orchestrator test       # mix test
docker run --rm scxml-orchestrator credo      # mix credo --strict
docker run --rm scxml-orchestrator format     # mix format --check-formatted
docker run --rm scxml-orchestrator compile    # mix compile --warnings-as-errors
docker run --rm scxml-orchestrator shell      # iex -S mix
docker run --rm scxml-orchestrator escript    # mix escript.build
```

> **Windows note:** the container runs Linux. Line endings are normalized to
> LF via the repo's `.gitattributes`, so a checkout on Windows (or Linux)
> yields LF files that `bin/run`, `mix format`, and Credo expect. If you
> bind-mount the repo for interactive work, avoid copying `deps/` / `_build/`
> from a Windows host into the mount, as those carry platform-specific
> artifacts.

## Scope / exclusions

Out of scope for this project: the visual editor, SCXML parsing/serialization
(handled by `scxml-parser`), HTTP/WebSocket transports, and distributed BEAM
(`Horde`). The public API is library-first; a transport layer can be layered
on top of `ScxmlEngine` later.
