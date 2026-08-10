Choosing BEAM with Elixir for an SCXML execution engine aligns with statechart execution semantics. The statechart model (isolated state, message-driven transitions, concurrent parallel regions, deterministic event queues) maps directly to OTP primitives.

Because the engine is decoupled and consumes a JSON AST, the architecture isolates the compilation phase (JSON AST $\rightarrow$ Derived Graph) from the execution processes.

---

### High-Level BEAM Engine Architecture

```
                    ┌─────────────────────────┐
                    │      JSON AST Input     │
                    └────────────┬────────────┘
                                 │
                                 ▼
                    ┌─────────────────────────┐
                    │  ScxmlEngine.Compiler   │ ◄── Pure functional transform
                    └────────────┬────────────┘     (Computes LCAs, Event Indexes)
                                 │
                                 ▼
                    ┌─────────────────────────┐
                    │  :persistent_term / ETS │ ◄── Zero-copy immutable storage
                    └────────────┬────────────┘     shared across all instances
                                 │
         ┌───────────────────────┼───────────────────────┐
         │ (Instantiate)         │ (Instantiate)         │ (Instantiate)
         ▼                       ▼                       ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ Instance Engine │     │ Instance Engine │     │ Instance Engine │
│   (GenServer)   │     │   (GenServer)   │     │   (GenServer)   │
└─────────────────┘     └─────────────────┘     └─────────────────┘
  • Active Set            • Active Set            • Active Set
  • Mailbox ($Q_{ext}$)   • Mailbox ($Q_{ext}$)   • Mailbox ($Q_{ext}$)
  • Queue ($Q_{int}$)     • Queue ($Q_{int}$)     • Queue ($Q_{int}$)

```

---

### Core Architectural Layering

#### 1. Zero-Copy Graph Compilation (`ScxmlEngine.Compiler`)

When a statechart JSON AST is ingested, it is compiled into a read-only `%ScxmlEngine.RuntimeGraph{}` struct.

To maximize BEAM performance:

- **Zero-Copy Memory Distribution:** Store compiled `%RuntimeGraph{}` structures in `:persistent_term` (or an ETS table with `read_concurrency: true`). Millions of running process instances can read the graph concurrently without copying the data structure into their process heaps.
- **Pre-Computed LCA Transitions:** Calculate Least Common Ancestor (LCA) paths, `exit_set`, and `entry_set` during this compile phase so that state transitions during runtime microsteps require simple map lookups.

```elixir
defmodule ScxmlEngine.RuntimeGraph do
  @type state_id :: String.t()

  defstruct [
    :id,
    :initial,
    :states,          # %{state_id => %RuntimeState{}}
    :parent_map,      # %{child_id => parent_id}
    :ancestors_map,   # %{state_id => [parent_ids...]}
    :event_index      # %{exact: %{}, patterns: []}
  ]
end

defmodule ScxmlEngine.RuntimeTransition do
  defstruct [
    :id,
    :event,
    :target,
    :type,            # :external | :internal
    :cond,            # String or parsed AST
    :actions,         # List of executable action maps
    :exit_set,        # [state_id] ordered bottom-up
    :entry_set,       # [state_id] ordered top-down
    :lca_id           # state_id of LCA
  ]
end

```

---

#### 2. Pattern & Wildcard Matching (`ScxmlEngine.EventMatcher`)

SCXML supports dot-delimited hierarchy (e.g., `user.login` matched by `user.*` or `*`). In Elixir, exact matches hit a map directly ($O(1)$), while pattern lookups use binary pattern matching or compiled prefix lists.

```elixir
defmodule ScxmlEngine.EventMatcher do
  @doc """
  Matches an incoming event name against a token/wildcard pattern.
  """
  def match?(pattern, event_name) when pattern == "*" or pattern == event_name, do: true

  def match?(pattern, event_name) do
    cond do
      String.contains?(pattern, " ") ->
        pattern
        |> String.split(" ", trim: true)
        |> Enum.any?(&match?(&1, event_name))

      String.ends_with?(pattern, ".*") ->
        prefix = String.slice(pattern, 0..(String.length(pattern) - 3))
        event_name == prefix or String.starts_with?(event_name, prefix <> ".")

      true ->
        false
    end
  end
end

```

---

#### 3. Statechart Instance Execution (`ScxmlEngine.Instance`)

Each running instance of a statechart maps to a single BEAM process (`GenServer` or `:gen_statem`).

- **Mailbox as $Q_{ext}$:** The process mailbox naturally serves as the external event queue. Incoming calls/casts are popped in sequence.
- **Process State as Memory Context:** The process holds the active state configuration (`MapSet`), the data model (`Map`), and the internal event queue (`:queue`).

```elixir
defmodule ScxmlEngine.Instance do
  use GenServer

  defstruct [
    :graph_id,             # Key to lookup %RuntimeGraph{} in :persistent_term
    :active_configuration, # MapSet of active atomic state IDs
    :datamodel,            # Map of runtime variables
    :internal_queue        # :queue of internal event maps
  ]

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def send_event(pid, event_name, payload \\ %{}) do
    GenServer.cast(pid, {:external_event, %{name: event_name, data: payload}})
  end

  # --- Server Callbacks ---

  @impl true
  def init(%{graph_id: graph_id, initial_datamodel: datamodel}) do
    graph = :persistent_term.get({:scxml_graph, graph_id})

    # Initialize state configuration starting from root initial target
    initial_states = resolve_initial_configuration(graph, [graph.initial])

    state = %__MODULE__{
      graph_id: graph_id,
      active_configuration: MapSet.new(initial_states),
      datamodel: Map.put(datamodel, "_event", nil),
      internal_queue: :queue.new()
    }

    # Run initial macrostep to settle eventless transitions / initial actions
    {:ok, run_macrostep(state)}
  end

  @impl true
  def handle_cast({:external_event, event}, state) do
    updated_state =
      state
      |> enqueue_external_event(event)
      |> run_macrostep()

    {:noreply, updated_state}
  end

  # --- Macrostep / Microstep Interpreter ---

  defp run_macrostep(state) do
    case pop_next_event(state) do
      {:ok, event, state_after_pop} ->
        state_after_event =
          state_after_pop
          |> update_datamodel("_event", event)
          |> process_microstep(event)

        # Loop until internal & external queues are drained and machine settles
        run_macrostep(state_after_event)

      :empty ->
        # Evaluate eventless transitions (null event) before idling
        evaluate_eventless_transitions(state)
    end
  end

  defp process_microstep(state, event) do
    graph = :persistent_term.get({:scxml_graph, state.graph_id})
    enabled_transitions = select_transitions(graph, state, event)

    if Enum.empty?(enabled_transitions) do
      state
    else
      Enum.reduce(enabled_transitions, state, fn transition, acc_state ->
        execute_transition(graph, acc_state, transition)
      end)
    end
  end

  defp execute_transition(graph, state, transition) do
    state
    # 1. Exit active states (bottom-up execution)
    |> execute_exit_actions(graph, transition.exit_set)
    |> mutate_active_config(&MapSet.difference(&1, MapSet.new(transition.exit_set)))
    # 2. Execute transition actions
    |> execute_action_list(transition.actions)
    # 3. Enter new states (top-down execution)
    |> execute_entry_actions(graph, transition.entry_set)
    |> mutate_active_config(&MapSet.union(&1, MapSet.new(transition.entry_set)))
  end

  defp pop_next_event(%{internal_queue: q} = state) do
    case :queue.out(q) do
      {{:value, event}, new_q} ->
        {:ok, event, %{state | internal_queue: new_q}}

      {:empty, _} ->
        :empty
    end
  end

  defp update_datamodel(state, key, val) do
    %{state | datamodel: Map.put(state.datamodel, key, val)}
  end

  defp mutate_active_config(state, fun) do
    %{state | active_configuration: fun.(state.active_configuration)}
  end

  defp resolve_initial_configuration(_graph, targets), do: targets
  defp select_transitions(_graph, _state, _event), do: []
  defp execute_exit_actions(state, _graph, _exit_set), do: state
  defp execute_entry_actions(state, _graph, _entry_set), do: state
  defp execute_action_list(state, _actions), do: state
  defp evaluate_eventless_transitions(state), do: state
end

```

---

### Expression Evaluation Strategy (`cond` & `expr`)

Guards (`cond="data.amount > 100"`) and script actions require evaluation against the instance's `datamodel`.

To maintain safety and decoupling:

1. **Restricted AST Evaluator:** Use a sandbox expression evaluator (such as `Abacus` or a simple custom parser over `Code.string_to_quoted/2` restricted to basic arithmetic, map access, and boolean operators).
2. **Avoid `Code.eval_string/2` in Production:** Invoking raw BEAM string evaluation exposes the runtime to remote code execution (RCE) if SCXML inputs originate from untrusted sources.

---

### OTP Supervision & Process Management

To orchestrate millions of concurrent state machines, manage process lifecycles via standard OTP abstractions:

```
                      ┌──────────────────────────────┐
                      │    ScxmlEngine.Supervisor    │
                      └──────────────┬───────────────┘
                                     │
           ┌─────────────────────────┴─────────────────────────┐
           ▼                                                   ▼
┌──────────────────────┐                            ┌──────────────────────┐
│ ScxmlEngine.Registry │                            │ DynamicSupervisor    │
│ (Via `Registry`)     │                            │ (Spawns Instances)   │
└──────────────────────┘                            └──────────────────────┘

```

- **Process Lookup:** Use Elixir’s native `Registry` (or `Horde.Registry` for distributed BEAM clusters across multiple nodes) to map `instance_id` strings to running `GenServer` PIDs.
- **Dynamic Spawning:** Use a `DynamicSupervisor` to spin up instances on demand via REST, WebSockets, or gRPC endpoints.
- **Fault Isolation:** If an expression evaluation fails or a state machine raises an unhandled error, the supervisor isolates the crash to that specific instance without impacting other state machines.
