defmodule ScxmlEngine.Compiler do
  @moduledoc """
  Compiles a deserialized `ScxmlEngine.RuntimeGraph` (raw state nodes produced
  by `ScxmlEngine.Document`) into a fully-indexed, execution-ready graph.

  Compilation is a **pure functional transform** with no process side effects
  (the only impure step is `store/1`, which hands the finished graph to
  `:persistent_term`). It performs the following:

    * Builds `parent_map` (`child_id => parent_id`).
    * Builds `ancestors_map` (`state_id => [immediate_parent, ... , root]`).
    * Builds `event_index` (`%{exact: %{event => [transition]}, patterns: [...]}`)
      so exact event lookups are O(1) and patterned transitions are scanned.
    * Pre-computes each transition's LCA `exit_set` (bottom-up) and `entry_set`
      (top-down) so runtime microsteps become pure map lookups.
    * Recomputes each compound/parallel state's `initial` chain resolution info.

  ## Storage

  The finished graph is stored in `:persistent_term` keyed by
  `{:scxml_graph, graph_id}` meaning thousands of concurrent `ScxmlEngine.Instance`
  processes can read it without copying it onto their own heaps.
  """

  alias ScxmlEngine.RuntimeGraph
  alias ScxmlEngine.RuntimeTransition

  @graph_prefix :scxml_graph

  @doc """
  Compile a deserialized raw `%RuntimeGraph{}` into a fully-indexed graph.
  Returns the compiled `%RuntimeGraph{}` (pure).
  """
  @spec compile(RuntimeGraph.t()) :: RuntimeGraph.t()
  def compile(%RuntimeGraph{} = raw) do
    parent_map = raw.parent_map || build_parent_map(raw.states)
    ancestors_map = build_ancestors_map(raw.states, parent_map)

    states = build_indexed_states(raw.states, parent_map, ancestors_map)

    event_index = build_event_index(states)

    %RuntimeGraph{
      id: raw.id,
      initial: raw.initial,
      states: states,
      parent_map: parent_map,
      ancestors_map: ancestors_map,
      event_index: event_index
    }
  end

  @doc """
  Compile, then store the finished graph in `:persistent_term` under the
  given `graph_id` (defaults to the graph's `id`, or a random id if absent).

  Returns `{:ok, graph_id}` where `graph_id` is the key used at runtime.
  Storing the same graph_id again replaces the previous graph.
  """
  @spec store(RuntimeGraph.t(), String.t() | nil) :: {:ok, String.t()}
  def store(%RuntimeGraph{} = raw, graph_id \\ nil) do
    graph = compile(raw)
    id = graph_id || graph.id || generate_id()
    :persistent_term.put({@graph_prefix, id}, graph)
    {:ok, id}
  end

  @doc """
  Fetch a previously stored compiled graph by `graph_id`, or `nil` if absent.
  """
  @spec fetch(String.t()) :: RuntimeGraph.t() | nil
  def fetch(graph_id) do
    :persistent_term.get({@graph_prefix, graph_id}, nil)
  end

  defp generate_id do
    "g-" <> (8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))
  end

  # ---------------------------------------------------------------------------
  # Parent & ancestors maps
  # ---------------------------------------------------------------------------

  # Fallback parent map builder. The parent map is normally populated during
  # deserialization (`Document.from_map/1`) because the parser AST is a nested
  # tree. When manually constructing a graph with a populated `states` map but
  # no parent map, parentage can only be inferred from the (already compiled)
  # ancestor relationships, which are not retained — so we return an empty map
  # and note that callers should provide `parent_map` explicitly. The compiler
  # treats a missing parent map as an empty one.
  defp build_parent_map(_states), do: %{}

  # Build ancestors map: state -> ordered [immediate parent ... root]
  defp build_ancestors_map(states, parent_map) do
    Map.new(states, fn {id, _state} ->
      {id, walk_parents(id, parent_map)}
    end)
  end

  # Ancestors ordered from immediate parent up to root (empty for a root state).
  defp walk_parents(id, parent_map) do
    case Map.get(parent_map, id) do
      nil -> []
      parent -> [parent | walk_parents(parent, parent_map)]
    end
  end

  # ---------------------------------------------------------------------------
  # Indexed states + LCA
  # ---------------------------------------------------------------------------

  defp build_indexed_states(states, parent_map, ancestors_map) do
    Map.new(states, fn {id, state} ->
      transitions =
        Enum.map(state.transitions, fn t ->
          resolved_targets = Enum.map(t.targets, &resolve_target(&1, states, parent_map))

          t = %{t | targets: resolved_targets}

          {exit_set, entry_set, lca_id} =
            compute_transition_path(t, state.id, parent_map, ancestors_map)

          %{t | exit_set: exit_set, entry_set: entry_set, lca_id: lca_id}
        end)

      {id, %{state | transitions: transitions}}
    end)
  end

  # Resolve a transition `target` (which may be a dotted hierarchical path such
  # as "active.hist" or a flat state id) into an actual leaf state id present in
  # the graph. Dotted paths are resolved downward through `parent_map`.
  #
  # Examples:
  #   "hist"           (flat id)         -> "hist"
  #   "active.hist"    (path)            -> "hist"
  #   "both.audio"     (parallel region) -> "audio"
  #
  # If a path does not resolve, the original target string is returned (it may
  # be a flat id that is valid on its own).
  defp resolve_target(target, states, parent_map) do
    if is_binary(target) and String.contains?(target, ".") do
      [head | tail] = String.split(target, ".", trim: true)

      if Map.has_key?(states, head) do
        case walk_path(head, tail, parent_map) do
          {:ok, leaf} -> leaf
          :error -> target
        end
      else
        target
      end
    else
      target
    end
  end

  # Walk downward through the hierarchy from `current`, requiring each segment
  # to be a direct child of the previous node. Returns `{:ok, leaf_id}` or
  # `:error` if the path is invalid.
  defp walk_path(current, [], _parent_map), do: {:ok, current}

  defp walk_path(current, [seg | rest], parent_map) do
    if Map.get(parent_map, seg) == current do
      walk_path(seg, rest, parent_map)
    else
      :error
    end
  end

  @doc """
  Compute the LCA exit/entry path for a transition from its source state.

  Mirrors UI-AST-RUNTIME §4:

    * An internal transition with no target produces empty exit/entry sets.
    * Otherwise the Least Common Ancestor of source and each target is found,
      the source's ancestors are exited bottom-up and targets' ancestors are
      entered top-down.

  For multiple targets (parallel-region entry) the per-target paths are merged,
  taking the union of exited states and the union (preserving top-down order)
  of entered states.

  Returns `{exit_set, entry_set, lca_id}`.
  """
  @spec compute_transition_path(RuntimeTransition.t(), String.t(), map(), map()) ::
          {[String.t()], [String.t()], String.t() | nil}
  def compute_transition_path(%RuntimeTransition{targets: []}, _source, _pm, _am) do
    {[], [], nil}
  end

  def compute_transition_path(%RuntimeTransition{} = t, source, _parent_map, ancestors_map) do
    Enum.reduce(t.targets, {[], [], nil}, fn target, {exit_acc, entry_acc, lca_acc} ->
      {exit_set, entry_set, lca_id} =
        lca_path(source, target, ancestors_map)

      {
        union_keep_order(exit_acc, exit_set),
        union_keep_order(entry_acc, entry_set),
        lca_acc || lca_id
      }
    end)
  end

  defp lca_path(source, target, ancestors_map) do
    source_ancestors = [source | Map.get(ancestors_map, source, [])]
    target_ancestors = [target | Map.get(ancestors_map, target, [])]

    lca =
      Enum.find(source_ancestors, fn sid ->
        sid in target_ancestors
      end)

    case lca do
      nil ->
        # No shared ancestor: the two states live in different root-level
        # subtrees. The whole source side (itself + ancestors) is exited and
        # the whole target side (itself + ancestors) is entered.
        {source_ancestors, Enum.reverse(target_ancestors), nil}

      lca ->
        exit_set =
          Enum.take_while(source_ancestors, fn sid ->
            sid != lca
          end)

        raw_entry =
          Enum.take_while(target_ancestors, fn sid ->
            sid != lca
          end)

        entry_set = Enum.reverse(raw_entry)

        {exit_set, entry_set, lca}
    end
  end

  # Concatenate while preserving order and dropping duplicates already present.
  defp union_keep_order(existing, new) do
    existing ++ Enum.reject(new, &(&1 in existing))
  end

  # ---------------------------------------------------------------------------
  # Event index
  # ---------------------------------------------------------------------------

  defp build_event_index(states) do
    transitions = Enum.flat_map(states, fn {_id, state} -> state.transitions end)

    {exact, patterns} =
      Enum.split_with(transitions, fn t ->
        event_exact?(t.event)
      end)

    exact_index =
      Enum.reduce(exact, %{}, fn t, acc ->
        event = t.event
        Map.update(acc, event, [t], &[t | &1])
      end)

    %{exact: exact_index, patterns: patterns}
  end

  # An event qualifies as `exact` if it has no wildcard/dot-prefix semantics and
  # isn't a tokenized (space-separated) pattern.
  defp event_exact?(nil), do: false
  defp event_exact?("*"), do: false

  defp event_exact?(event) do
    not String.contains?(event, " ") and not String.ends_with?(event, ".*")
  end

  @doc false
  def graph_prefix, do: @graph_prefix
end
