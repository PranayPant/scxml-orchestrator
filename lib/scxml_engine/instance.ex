defmodule ScxmlEngine.Instance do
  @moduledoc """
  A single running statechart instance, implemented as a `GenServer`.

  The statechart's **external event queue** (`Q_ext`) is the process mailbox
  itself — incoming `send_event/3` calls are `cast`s and are processed in
  mailbox order. The **internal event queue** (`Q_int`) is a `:queue` held in
  process state. The process state also holds the **active configuration**
  (`MapSet` of active state ids) and the **datamodel** (`Map`).

  Interpretation follows the macrostep/microstep model:

    * A macrostep processes all queued events until both queues are drained.
    * Each microstep selects the enabled transitions for the current event,
      executes them (exit bottom-up → transition actions → enter top-down),
      then settles any eventless (`nil`-event) transitions.
    * `raise` actions push new events onto the internal queue, which are then
      processed before the next external event.

  ## API

      {:ok, pid} = ScxmlEngine.Instance.start_link(graph_id: "g1")
      ScxmlEngine.Instance.send_event(pid, "next")
      ScxmlEngine.Instance.active_configuration(pid)
  """

  use GenServer

  alias ScxmlEngine.Compiler
  alias ScxmlEngine.EventMatcher
  alias ScxmlEngine.Expression
  alias ScxmlEngine.Instance
  alias ScxmlEngine.Registry

  require Logger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @type event :: %{name: String.t(), data: term()}

  defstruct [
    :graph_id,
    active_configuration: MapSet.new(),
    datamodel: %{},
    # Explicitly tracked instance-level execution status.
    # Updated through lifecycle transitions rather than derived from config.
    execution_status: :idle,
    # Maps each active state id to its per-state status (`:running | :completed | :error`).
    # Updated on each activate/deactivate rather than derived from the state type.
    state_statuses: %{},
    internal_queue: :queue.new(),
    # Maps a compound/parallel region's parent id to its last-active direct
    # child ids — used to restore `history` pseudo-states on re-entry.
    history: %{}
  ]

  @doc """
  Start a statechart instance for a previously stored graph.

  Options:
    * `:graph_id` (required) — the graph id returned by `Compiler.store/2`.
    * `:initial_datamodel` — a map of initial data values.
    * `:name` — optional registered name.
    * All other `GenServer` options are forwarded.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Send an external event to the instance and wait until it is fully processed
  (the macrostep completes). Returns `:ok`.

  Because the event is processed synchronously before returning, this gives a
  deterministic "step" API well suited to tests and orchestrators.
  """
  @spec send_event(GenServer.server(), String.t(), term()) :: :ok
  def send_event(pid, event_name, payload \\ %{}) do
    GenServer.call(pid, {:external_event, %{name: event_name, data: payload}})
  end

  @doc """
  Query the currently active configuration (a `MapSet` of state ids).
  """
  @spec active_configuration(GenServer.server()) :: MapSet.t()
  def active_configuration(pid) do
    GenServer.call(pid, :active_configuration)
  end

  @doc """
  Query the current datamodel.
  """

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @spec datamodel(GenServer.server()) :: map()
  def datamodel(pid) do
    GenServer.call(pid, :datamodel)
  end

  @doc """
  Query whether the instance has settled (no active config) / whether a final
  state is active. Returns `true` when the active configuration is empty.
  """
  @spec done?(GenServer.server()) :: boolean()
  def done?(pid) do
    pid |> active_configuration() |> MapSet.size() == 0
  end

  @doc """
  Return the execution status of an instance.

  Status is tracked **explicitly** in the process state rather than derived
  from the active configuration. It is updated at each lifecycle point:

  * `:idle` — Instance created; at initial configuration, no events processed.
  * `:running` — Events are being processed; transitions are active.
  * `:completed` — All final states reached.
  * `:error` — (reserved) An unhandled error occurred.
  """
  @type execution_status :: :idle | :running | :completed | :error

  @spec execution_status(GenServer.server()) :: execution_status()
  def execution_status(pid) do
    GenServer.call(pid, :execution_status)
  end

  @doc """
  Return the status of each active state in the current configuration.

  Returns a list of `%{id: String.t(), status: state_status(), type: state_type()}` maps.

  Per-state statuses are tracked explicitly in the `state_statuses` map and
  set on each state activation:

  * `:running` — State is active and not a final state.
  * `:completed` — State is active and is a final state (`<state type="final">`).

  States not in the active configuration are omitted entirely — the caller only
  sees what's currently rendered on the canvas.
  """
  @type state_status :: :running | :completed | :error
  @type state_info :: %{id: String.t(), status: state_status(), type: ScxmlEngine.RuntimeState.state_type()}

  @spec active_states(GenServer.server()) :: [state_info()]
  def active_states(pid) do
    GenServer.call(pid, :active_states)
  end

  @impl true
  def init(opts) do
    graph_id = Keyword.fetch!(opts, :graph_id)
    instance_id = Keyword.get(opts, :instance_id)
    initial_datamodel = Keyword.get(opts, :initial_datamodel, %{})
    graph = Compiler.fetch(graph_id)

    if is_nil(graph) do
      {:stop, {:graph_not_found, graph_id}}
    else
      # Register this process under `instance_id` so callers can look it up.
      # `Registry.register/3` registers the calling process, so this must run
      # inside the instance process itself.
      if is_binary(instance_id), do: Registry.register(instance_id, self())

      initial_states = resolve_initial_configuration(graph)

      state = %Instance{
        graph_id: graph_id,
        active_configuration: MapSet.new(),
        datamodel: Map.put(initial_datamodel, "_event", nil),
        execution_status: :idle,
        state_statuses: %{},
        internal_queue: :queue.new(),
        history: %{}
      }

      # Enter the initial states top-down, running their on_entry actions.
      state = enter_initial_configuration(state, graph, initial_states)

      # Run the initial macrostep to settle any eventless transitions.
      # Status remains `:idle` until the first external event is processed.
      {:ok, run_macrostep(state)}
    end
  end

  @impl true
  def handle_call({:external_event, event}, _from, state) do
    state = %{state | execution_status: :running}

    state =
      run_macrostep(%{
        state
        | internal_queue: :queue.in({:external, event}, state.internal_queue)
      })

    graph = Compiler.fetch(state.graph_id)
    state = set_execution_status(state, graph)

    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Macrostep / microstep interpreter
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call(:active_configuration, _from, state) do
    {:reply, state.active_configuration, state}
  end

  @impl true
  def handle_call(:datamodel, _from, state) do
    {:reply, state.datamodel, state}
  end

  @impl true
  def handle_call(:active_states, _from, state) do
    graph = Compiler.fetch(state.graph_id)

    states_info =
      Enum.map(MapSet.to_list(state.active_configuration), fn state_id ->
        state_node = Map.fetch!(graph.states, state_id)

        %{
          id: state_id,
          status: Map.get(state.state_statuses, state_id, :running),
          type: state_node.type
        }
      end)

    {:reply, states_info, state}
  end

  @impl true
  def handle_call(:execution_status, _from, state) do
    {:reply, state.execution_status, state}
  end

  @doc false
  # Runs microsteps until the internal AND external event queues are drained,
  # then settles eventless transitions.
  def run_macrostep(state) do
    case pop_next_event(state) do
      {:ok, event, state_after_pop} ->
        state_after_event =
          state_after_pop
          |> put_datamodel("_event", event)
          |> process_microstep(event)

        Logger.debug("macrostep: event settled",
          event: event.name,
          config: Enum.sort(MapSet.to_list(state_after_event.active_configuration)),
          execution_status: state_after_event.execution_status,
          done: MapSet.size(state_after_event.active_configuration) == 0
        )

        run_macrostep(state_after_event)

      :empty ->
        evaluate_eventless_transitions(state)
    end
  end

  defp pop_next_event(%Instance{internal_queue: q} = state) do
    case :queue.out(q) do
      {{:value, {:external, event}}, new_q} -> {:ok, event, %{state | internal_queue: new_q}}
      {{:value, {:internal, event}}, new_q} -> {:ok, event, %{state | internal_queue: new_q}}
      {:empty, _} -> :empty
    end
  end

  # One event -> select and execute enabled transitions, then settle eventless.
  defp process_microstep(state, event) do
    graph = Compiler.fetch(state.graph_id)
    enabled_transitions = select_transitions(graph, state, event)

    if Enum.empty?(enabled_transitions) do
      state
    else
      Enum.reduce(enabled_transitions, state, fn transition, acc_state ->
        execute_transition(graph, acc_state, transition)
      end)
    end
  end

  # Select the first enabled transition (by event match + guard) for each
  # active state. Only transitions originating from states in the active
  # configuration are considered, matching SCXML's per-state priority where a
  # descendant transition beats its ancestor's (we process active states in
  # an order that gives descendants priority).
  defp select_transitions(graph, state, event) do
    # Order active states so that deeper (more specific) states are handled
    # first, giving descendant transitions priority over ancestor transitions.
    active_states = Enum.sort_by(state.active_configuration, &(-length(Map.get(graph.ancestors_map, &1, []))))

    matched =
      Enum.flat_map(active_states, fn state_id ->
        the_state = Map.fetch!(graph.states, state_id)

        case find_enabled_transition(the_state, event, state.datamodel) do
          nil -> []
          transition -> [{state_id, transition}]
        end
      end)

    Logger.debug("microstep: enabled transitions",
      event: event.name,
      active_config: Enum.sort(MapSet.to_list(state.active_configuration)),
      enabled:
        Enum.map(matched, fn {state_id, t} ->
          %{
            from: state_id,
            event: t.event,
            targets: t.targets,
            lca: t.lca_id,
            static_exit_set: t.exit_set,
            static_entry_set: t.entry_set
          }
        end)
    )

    Enum.map(matched, fn {_state_id, transition} -> transition end)
  end

  defp find_enabled_transition(the_state, event, datamodel) do
    Enum.find(the_state.transitions, fn t ->
      event_matches?(t.event, event.name) and
        Expression.guard_true?(t.cond, datamodel)
    end)
  end

  defp event_matches?(nil, _event_name), do: false

  defp event_matches?(pattern, event_name) do
    EventMatcher.match?(pattern, event_name)
  end

  # Execute a single transition:
  #   1. Exit states in `exit_set` bottom-up (run on_exit), removing from active config.
  #   2. Run the transition's executable actions.
  #   3. Enter states in `entry_set` top-down (run on_entry), adding to active config.
  #      Compound/parallel states are expanded recursively into their initial child.
  defp execute_transition(graph, state, transition) do
    exit_set = compute_exit_set(graph, state, transition)
    before_config = Enum.sort(MapSet.to_list(state.active_configuration))

    Logger.debug("execute_transition: before",
      event: transition.event,
      targets: transition.targets,
      lca: transition.lca_id,
      active_config: before_config,
      runtime_exit_set: exit_set,
      entry_set: transition.entry_set
    )

    result =
      state
      |> record_exit_histories(graph, exit_set)
      |> execute_exits(graph, exit_set)
      |> execute_action_list(transition.actions)
      |> execute_entries(graph, transition.entry_set)

    Logger.debug("execute_transition: after",
      event: transition.event,
      targets: transition.targets,
      active_config_before: before_config,
      active_config_after: Enum.sort(MapSet.to_list(result.active_configuration))
    )

    result
  end

  # The states to exit for a transition are the currently-active states that
  # are proper descendants of the transition's LCA and are not on the entry
  # path. This is computed at runtime because it depends on the active
  # configuration: e.g. a transition on a compound state targeting one of its
  # own children must still exit the compound's *other* active descendants.
  # Internal transitions (no target) exit nothing.
  defp compute_exit_set(graph, state, transition) do
    if Enum.empty?(transition.targets) do
      []
    else
      lca = transition.lca_id
      entry_set = MapSet.new(transition.entry_set)

      state.active_configuration
      |> Enum.filter(fn sid ->
        proper_descendant_of?(sid, lca, graph) and not MapSet.member?(entry_set, sid)
      end)
      |> Enum.sort_by(&(-length(Map.get(graph.ancestors_map, &1, []))))
    end
  end

  defp proper_descendant_of?(_sid, nil, _graph), do: true

  defp proper_descendant_of?(sid, lca, graph) do
    sid != lca and Enum.member?(Map.get(graph.ancestors_map, sid, []), lca)
  end

  # Record the last-active direct children of every compound/parallel region
  # being exited, so their `history` pseudo-states can restore them. This runs
  # before any deactivation so the recorded children are still intact.
  defp record_exit_histories(state, graph, exit_set) do
    Enum.reduce(exit_set, state, fn sid, acc ->
      case Map.get(graph.states, sid) do
        %{type: type} when type in [:compound, :parallel] ->
          active_children =
            Enum.filter(direct_children(sid, graph), &MapSet.member?(state.active_configuration, &1))

          record_history(acc, sid, active_children)

        _ ->
          acc
      end
    end)
  end

  defp execute_exits(state, _graph, []), do: state

  # Active configuration ids always resolve to graph states (dangling history
  # defaults are filtered at entry), so fetch directly.
  defp execute_exits(%Instance{} = state, graph, [id | rest]) do
    the_state = Map.fetch!(graph.states, id)

    state =
      case the_state.type do
        # A history pseudo-state in the active configuration is deactivated
        # like any other state (it has no exit actions).
        :history ->
          deactivate(state, id)

        _ ->
          state
          |> execute_action_list(the_state.on_exit)
          |> deactivate(id)
      end

    execute_exits(state, graph, rest)
  end

  defp execute_entries(state, _graph, []), do: state

  defp execute_entries(%Instance{} = state, graph, [id | rest]) do
    the_state = Map.get(graph.states, id)
    remaining = MapSet.new(rest)

    state =
      cond do
        is_nil(the_state) ->
          state

        the_state.type == :history ->
          enter_history(state, graph, the_state)

        true ->
          state
          |> activate(graph, id)
          |> execute_action_list(the_state.on_entry)
          |> enter_default_children(graph, id, remaining)
      end

    execute_entries(state, graph, rest)
  end

  # Enter a compound/parallel state's default children (its initial child for a
  # compound, all child regions for a parallel) unless those children are
  # explicitly targeted by the remaining entry set or are already active.
  # This gives correct SCXML default-entry semantics on top of the precomputed
  # LCA `entry_set`.
  defp enter_default_children(state, graph, id, remaining) do
    # If the remaining entry set explicitly targets a descendant of `id` (e.g.
    # a history pseudo-state or a specific child), don't enter defaults here —
    # the more specific entry will select the children.
    if Enum.any?(remaining, fn r -> descendant_of?(r, id, graph) end) do
      state
    else
      case Map.get(graph.states, id) do
        %{type: :compound, initial: child} when is_binary(child) ->
          enter_if_default(state, graph, child, remaining)

        %{type: :parallel} = p ->
          Enum.reduce(direct_children(p.id, graph), state, fn child, acc ->
            enter_if_default(acc, graph, child, remaining)
          end)

        _ ->
          state
      end
    end
  end

  defp descendant_of?(r, id, graph) do
    r != id and Enum.member?(Map.get(graph.ancestors_map, r, []), id)
  end

  defp enter_if_default(state, graph, child, remaining) do
    state
    |> activate(graph, child)
    |> execute_action_list(graph.states[child].on_entry)
    |> enter_default_children(graph, child, remaining)
  end

  # Entering a history pseudo-state: restore the last active children of its
  # parent region (shallow = direct children, deep = all descendants), or fall
  # back to the history node's default target(s).
  defp enter_history(state, graph, history_state) do
    parent_id = Map.get(graph.parent_map, history_state.id)
    parent = Map.get(graph.states, parent_id)

    parent = parent || history_state

    restored =
      case history_state.history_type do
        :deep -> deep_restore(state, graph, parent)
        _ -> shallow_restore(state, parent)
      end

    targets =
      case restored do
        [] ->
          # No recorded history: fall back to the history node's default
          # target(s), or (per SCXML) the parent region's initial child.
          case history_state.history_targets do
            nil ->
              case Map.get(graph.states, parent.id) do
                %{initial: child} when is_binary(child) -> [child]
                _ -> []
              end

            ids ->
              ids
          end

        ids ->
          ids
      end

    # Only restore targets that exist in the graph — a dangling default target
    # is skipped rather than crashing later lookups.
    Enum.reduce(Enum.reverse(targets), state, fn target, acc ->
      if Map.has_key?(graph.states, target) do
        acc
        |> activate(graph, target)
        |> execute_entry_chain(graph, target)
      else
        acc
      end
    end)
  end

  # Previously-recorded active children of the region (already in execution
  # order from the record step).
  defp shallow_restore(state, parent) do
    Map.get(state.history, parent.id, [])
  end

  # -- initial configuration -------------------------------------------------
  defp deep_restore(state, graph, parent) do
    Enum.flat_map(shallow_restore(state, parent), fn child ->
      [child | collect_descendants(child, graph)]
    end)
  end

  defp collect_descendants(id, graph) do
    id
    |> direct_children(graph)
    |> Enum.flat_map(fn child -> [child] ++ collect_descendants(child, graph) end)
  end

  @doc false
  # Resolve the full initial active configuration (including recursive
  # expansion of compound/parallel initial children and history defaults).
  def resolve_initial_configuration(graph) do
    initial_id = graph.initial

    if is_nil(initial_id) do
      []
    else
      expand_initial([initial_id], graph)
    end
  end

  defp expand_initial(ids, graph) do
    Enum.flat_map(ids, fn id ->
      case Map.get(graph.states, id) do
        nil ->
          [id]

        state ->
          case state.type do
            :history ->
              default = state.history_targets || []
              [id | expand_initial(default, graph)]

            :compound ->
              child = state.initial
              if child, do: [id | expand_initial([child], graph)], else: [id]

            :parallel ->
              children = direct_children(state.id, graph)
              [id | expand_initial(children, graph)]

            _ ->
              [id]
          end
      end
    end)
  end

  # Enter the resolved initial configuration top-down, running each state's
  # on_entry actions and adding it to the active configuration.
  defp enter_initial_configuration(state, graph, ids) do
    Enum.reduce(ids, state, fn id, acc ->
      the_state = Map.get(graph.states, id)

      acc =
        case the_state do
          nil ->
            acc

          %{type: :history} ->
            activate(acc, graph, id)

          _ ->
            acc
            |> activate(graph, id)
            |> execute_action_list(the_state.on_entry)
        end

      acc
    end)
  end

  # -- entry chains / history -------------------------------------------------

  # After activating a state, if it's compound/parallel, descend into its
  # initial children (used when entering a specific child from a history).
  defp execute_entry_chain(state, graph, id) do
    case Map.fetch!(graph.states, id) do
      %{type: :compound, initial: child} when not is_nil(child) ->
        state
        |> activate(graph, child)
        |> execute_action_list(graph.states[child].on_entry)
        |> execute_entry_chain(graph, child)

      %{type: :parallel} = p ->
        children = direct_children(p.id, graph)

        Enum.reduce(children, state, fn child, acc ->
          acc
          |> activate(graph, child)
          |> execute_action_list(graph.states[child].on_entry)
          |> execute_entry_chain(graph, child)
        end)

      _ ->
        state
    end
  end

  defp direct_children(parent_id, graph) do
    graph.states
    |> Enum.filter(fn {_id, s} -> Map.get(graph.parent_map, s.id) == parent_id end)
    |> Enum.map(fn {id, _s} -> id end)
    |> Enum.sort()
  end

  # -- actions ----------------------------------------------------------------

  # Execute a list of executable action maps (parser `ExecutableContent`).
  # Recognized `kind`s: raise, assign, log, if/elseif/else, foreach, send,
  # cancel, script. Unsupported kinds are ignored.
  defp execute_action_list(state, actions) do
    Enum.reduce(actions, state, fn action, acc -> execute_action(action, acc) end)
  end

  defp execute_action(%{"kind" => "raise", "event" => event}, state) do
    enqueue_internal(state, %{name: event, data: %{}})
  end

  defp execute_action(%{"kind" => "assign", "location" => location} = action, state) do
    value =
      case action do
        %{"expr" => expr} when is_binary(expr) ->
          case Expression.evaluate(expr, state.datamodel) do
            {:ok, v} -> v
            {:error, _} -> nil
          end

        %{"value" => v} ->
          v

        _ ->
          nil
      end

    put_datamodel_path(state, location, value)
  end

  defp execute_action(%{"kind" => "log"} = action, state) do
    label = Map.get(action, "label", "log")
    expr = Map.get(action, "expr")

    if is_binary(expr) do
      case Expression.evaluate(expr, state.datamodel) do
        {:ok, value} -> Logger.info("[#{label}] #{inspect(value)}")
        {:error, _} -> Logger.info("[#{label}] #{expr}")
      end
    end

    state
  end

  defp execute_action(%{"kind" => "if", "cond" => cond, "executable" => body}, state) do
    if Expression.guard_true?(cond, state.datamodel) do
      execute_action_list(state, body)
    else
      state
    end
  end

  defp execute_action(%{"kind" => "elseif", "cond" => cond, "executable" => body}, state) do
    if Expression.guard_true?(cond, state.datamodel) do
      execute_action_list(state, body)
    else
      state
    end
  end

  defp execute_action(%{"kind" => "else", "executable" => body}, state) do
    execute_action_list(state, body)
  end

  defp execute_action(%{"kind" => "foreach"} = action, state) do
    array_expr = Map.get(action, "array", "")
    item = Map.get(action, "item")
    body = Map.get(action, "executable", [])

    case Expression.evaluate(array_expr, state.datamodel) do
      {:ok, list} when is_list(list) ->
        Enum.reduce(list, state, fn element, acc ->
          dm = put_loop_var(acc.datamodel, item, element)
          execute_action_list(%{acc | datamodel: dm}, body)
        end)

      _ ->
        state
    end
  end

  defp execute_action(%{"kind" => "send"} = action, state) do
    # A simple send without delay is raised immediately as an internal event.
    # Delayed sends (delay/delayexpr) are currently not scheduled; they are
    # logged and ignored to keep the engine deterministic.
    event_name =
      cond do
        is_binary(Map.get(action, "event")) ->
          Map.get(action, "event")

        is_binary(Map.get(action, "eventexpr")) ->
          case Expression.evaluate(Map.get(action, "eventexpr"), state.datamodel) do
            {:ok, v} when is_binary(v) -> v
            _ -> nil
          end

        true ->
          nil
      end

    if is_binary(event_name) do
      enqueue_internal(state, %{name: event_name, data: %{}})
    else
      state
    end
  end

  defp execute_action(%{"kind" => "cancel"}, state), do: state
  defp execute_action(%{"kind" => "script"}, state), do: state
  defp execute_action(_other, state), do: state

  defp enqueue_internal(%Instance{internal_queue: q} = state, event) do
    %{state | internal_queue: :queue.in({:internal, event}, q)}
  end

  defp record_history(state, region_id, active_children) do
    %{state | history: Map.put(state.history, region_id, active_children)}
  end

  # -- eventless transitions --------------------------------------------------

  # Evaluate and execute transitions with no event (nil event) until the
  # machine settles. Compound/parallel entry is expanded within execute_entries.
  defp evaluate_eventless_transitions(state) do
    graph = Compiler.fetch(state.graph_id)

    case find_eventless_transition(graph, state) do
      # -- datamodel helpers -----------------------------------------------------
      nil ->
        state

      {_state_id, transition} ->
        state
        |> put_datamodel("_event", %{name: "__eventless__", data: %{}})
        |> then(&execute_transition(graph, &1, transition))
        |> evaluate_eventless_transitions()
    end
  end

  defp find_eventless_transition(graph, state) do
    active_states = Enum.sort_by(state.active_configuration, &(-length(Map.get(graph.ancestors_map, &1, []))))

    Enum.reduce_while(active_states, nil, fn state_id, _acc ->
      the_state = Map.fetch!(graph.states, state_id)

      case Enum.find(the_state.transitions, fn t ->
             is_nil(t.event) and Expression.guard_true?(t.cond, state.datamodel)
           end) do
        nil -> {:cont, nil}
        transition -> {:halt, {state_id, transition}}
      end
    end)
  end

  defp put_datamodel(state, key, val) do
    %{state | datamodel: Map.put(state.datamodel, key, val)}
  end

  # Set a value at a dotted location path like `data.foo.bar` or `foo`.
  defp put_datamodel_path(state, location, value) do
    path =
      location
      |> String.replace(~r/\[["']?([^"'\]]+)["']?\]/, ".\\1")
      |> String.split(".", trim: true)

    dm = update_nested(state.datamodel, path, value)
    %{state | datamodel: dm}
  end

  defp update_nested(map, [key], value), do: Map.put(map, key, value)

  defp update_nested(map, [key | rest], value) do
    nested = Map.get(map, key, %{})
    Map.put(map, key, update_nested(nested, rest, value))
  end

  defp put_loop_var(dm, item, value) when is_binary(item), do: Map.put(dm, item, value)
  defp put_loop_var(dm, _item, _value), do: dm

  # Evaluate the final execution status after a macrostep settles.
  # Uses the active configuration and per-state statuses to determine
  # whether the instance is :running, :completed, or :error.
  defp set_execution_status(state, _graph) do
    if MapSet.size(state.active_configuration) == 0 do
      %{state | execution_status: :completed}
    else
      has_final? =
        Enum.any?(state.state_statuses, fn {_id, status} ->
          status == :completed
        end)

      if has_final? do
        %{state | execution_status: :completed}
      else
        %{state | execution_status: :running}
      end
    end
  end

  defp activate(state, graph, id) do
    the_state = Map.get(graph.states, id)

    status =
      cond do
        is_nil(the_state) -> :running
        the_state.type == :final -> :completed
        true -> :running
      end

    %{
      state
      | active_configuration: MapSet.put(state.active_configuration, id),
        state_statuses: Map.put(state.state_statuses, id, status)
    }
  end

  defp deactivate(state, id) do
    %{
      state
      | active_configuration: MapSet.delete(state.active_configuration, id),
        state_statuses: Map.delete(state.state_statuses, id)
    }
  end
end
