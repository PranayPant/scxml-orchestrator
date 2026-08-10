defmodule ScxmlEngine.Document do
  @moduledoc """
  Ingestion of a parser AST JSON document into the runtime structs.

  The input contract is the **actual AST produced by the `scxml-parser`
  library**, not the older `CanonicalStatechartAST` prototype. Its shape is:

      %{
        "scxml" => %{
          "id" => "...", "name" => "...", "version" => "...", "initial" => "rootInitial",
          "states" => [ %StateNode{}, ... ],
          "parallels" => [ %ParallelNode{}, ... ],
          "finals" => [ %FinalNode{}, ... ],
          "scripts" => [...], "datamodelChildren" => [...], "metadata" => [...]
        }
      }

  Node kinds:
    * `state`     -> `StateNode`  (`type` annotation: `compound | atomic | initial`, `initial?`, `transitions[]`, `states[]`, `parallels[]`, `finals[]`, `history[]`, `onentry?`, `onexit?`, `metadata[]`)
    * `parallel`  -> `ParallelNode` (no `type` key; hosts child states/parallels/finals)
    * `final`     -> `FinalNode` (`id`, `donedata?`, `onentry?`, `onexit?`, `metadata[]`)
    * `history`   -> `HistoryNode` (`id`, `type?` shallow|deep, `transition?` default)

  Layout data lives opaquely inside `metadata` blocks and is intentionally
  ignored here — the runtime does not need visual coordinates.

  The functions in this module are pure and side-effect free. Indexing /
  pre-computation (parent map, ancestors, LCA paths) is performed later by
  `ScxmlEngine.Compiler.compile/1`.
  """

  alias ScxmlEngine.RuntimeGraph
  alias ScxmlEngine.RuntimeState
  alias ScxmlEngine.RuntimeTransition

  @doc """
  Parse a JSON *string* in the parser's `SCXMLDocument` shape and deserialize
  it into an internal `ScxmlEngine.RuntimeGraph` whose `states` map holds
  `%RuntimeState{}` structs (transitions already split into `targets` lists).

  Returns `{:ok, %RuntimeGraph{}}` or `{:error, reason}`.

  ## Examples

      iex> {:ok, graph} = ScxmlEngine.Document.load(json_string)
  """
  @spec load(String.t()) :: {:ok, RuntimeGraph.t()} | {:error, term()}
  def load(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, from_map(decoded)}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  @doc """
  Deserialize an already-decoded map (the parser's `SCXMLDocument` shape) into
  a `%RuntimeGraph{}` of raw runtime states. Indexing is done by
  `ScxmlEngine.Compiler.compile/1`.
  """
  @spec from_map(map()) :: RuntimeGraph.t()
  def from_map(%{"scxml" => scxml}) when is_map(scxml) do
    initial = Map.get(scxml, "initial")
    id = Map.get(scxml, "id") || Map.get(scxml, "name")

    {states, parent_map} = build_top_level(scxml)

    %RuntimeGraph{
      id: id,
      initial: initial,
      states: states,
      parent_map: parent_map
    }
  end

  def from_map(other) do
    raise ArgumentError, "expected {\"scxml\": ...} document, got: #{inspect(other)}"
  end

  # ---------------------------------------------------------------------------
  # Node map -> %RuntimeState{}
  # ---------------------------------------------------------------------------

  # Build all top-level node arrays. Each array provides a kind hint so that a
  # `final`/`history`/`parallel` node is identified correctly even when it lacks
  # a marker field (e.g. a `final` with no `donedata`).
  defp build_top_level(scxml) do
    build_nodes_with_hints(
      [{"states", :state}, {"parallels", :parallel}, {"finals", :final}, {"history", :history}],
      scxml,
      %{},
      %{}
    )
  end

  # Returns `{state, flat_children_map, parent_map}` where descendants are
  # keyed by id and parentage of every descendant is recorded.
  defp build_node(node, parent_id, kind_hint) when is_map(node) do
    id = Map.fetch!(node, "id")

    case resolve_kind(kind_hint, node) do
      :state -> build_state(id, node, parent_id)
      :parallel -> build_state(id, node, parent_id, :parallel)
      :final -> build_terminal(id, node, :final, parent_id)
      :history -> build_history(id, node, parent_id)
    end
  end

  # Determine the node kind. The array hint takes precedence; the node's own
  # shape is used as a fallback for hand-written docs.
  defp resolve_kind(hint, node) do
    case hint do
      :state ->
        cond do
          is_map(Map.get(node, "transition")) -> :history
          node["type"] == "final" -> :final
          true -> :state
        end

      other ->
        other
    end
  end

  # Iterate over the four arrays in the document, building their nodes with the
  # matching kind hint, and record child parentage recursively.
  defp build_nodes_with_hints(array_specs, container, states_acc, parent_acc) do
    Enum.reduce(array_specs, {states_acc, parent_acc}, fn {key, hint}, {states_acc, parent_acc} ->
      nodes = container |> Map.get(key, []) |> List.wrap()

      Enum.reduce(nodes, {states_acc, parent_acc}, fn node, {states_acc, parent_acc} ->
        {state, children, parent_map} = build_node(node, nil, hint)
        states_acc = Map.put(states_acc, state.id, state)
        states_acc = Map.merge(states_acc, children)
        {states_acc, Map.merge(parent_acc, parent_map)}
      end)
    end)
  end

  defp build_state(id, node, parent_id, hint \\ :state) do
    state = %RuntimeState{
      id: id,
      type: resolve_state_type(node, hint),
      initial: Map.get(node, "initial"),
      on_entry: node |> Map.get("onentry", []) |> List.wrap(),
      on_exit: node |> Map.get("onexit", []) |> List.wrap(),
      transitions: build_transitions(node, id)
    }

    children =
      Enum.flat_map(
        [{"states", :state}, {"parallels", :parallel}, {"finals", :final}, {"history", :history}],
        fn {key, hint} ->
          node
          |> Map.get(key, [])
          |> List.wrap()
          |> Enum.map(&{&1, hint})
        end
      )

    {child_states, child_parents} = build_child_nodes(children, id)

    parent_map =
      if is_nil(parent_id), do: child_parents, else: Map.put(child_parents, id, parent_id)

    {state, child_states, parent_map}
  end

  defp resolve_state_type(node, hint) do
    cond do
      hint == :parallel -> :parallel
      hint == :final -> :final
      hint == :history -> :history
      node["type"] == "final" -> :final
      is_map(Map.get(node, "transition")) -> :history
      Map.has_key?(node, "donedata") -> :final
      node["type"] == "compound" -> :compound
      has_children?(node) -> :compound
      true -> :atomic
    end
  end

  defp build_terminal(id, node, type, parent_id) do
    state = %RuntimeState{
      id: id,
      type: type,
      on_entry: node |> Map.get("onentry", []) |> List.wrap(),
      on_exit: node |> Map.get("onexit", []) |> List.wrap()
    }

    parent_map = if is_nil(parent_id), do: %{}, else: %{id => parent_id}

    {state, %{}, parent_map}
  end

  defp build_history(id, node, parent_id) do
    history_type =
      case node["type"] do
        "deep" -> :deep
        _ -> :shallow
      end

    default_targets =
      case node["transition"] do
        %{"target" => target} when is_binary(target) -> split_targets(target)
        _ -> nil
      end

    state = %RuntimeState{
      id: id,
      type: :history,
      history_type: history_type,
      history_targets: default_targets
    }

    parent_map = if is_nil(parent_id), do: %{}, else: %{id => parent_id}

    {state, %{}, parent_map}
  end

  # Builds the descendant states of a given parent node list. Children arrive as
  # `{node, kind_hint}` tuples so array membership is preserved.
  defp build_child_nodes(children, parent_id) do
    Enum.reduce(children, {%{}, %{}}, fn {node, hint}, {states_acc, parent_acc} ->
      {state, child_states, child_parents} = build_node(node, parent_id, hint)
      states_acc = Map.put(states_acc, state.id, state)
      states_acc = Map.merge(states_acc, child_states)
      parent_acc = Map.merge(parent_acc, child_parents)
      {states_acc, parent_acc}
    end)
  end

  defp has_children?(node) do
    Enum.any?(["states", "parallels", "finals", "history"], fn key ->
      node |> Map.get(key, []) |> List.wrap() |> Enum.any?()
    end)
  end

  # ---------------------------------------------------------------------------
  # Transitions
  # ---------------------------------------------------------------------------

  defp build_transitions(node, _source_id) do
    node
    |> Map.get("transitions", [])
    |> List.wrap()
    |> Enum.map(fn t ->
      target_string = Map.get(t, "target")
      targets = if is_binary(target_string), do: split_targets(target_string), else: []

      %RuntimeTransition{
        id: Map.get(t, "id"),
        event: Map.get(t, "event"),
        targets: targets,
        target_string: target_string,
        type: if(Map.get(t, "type") == "internal", do: :internal, else: :external),
        cond: Map.get(t, "cond"),
        actions: t |> Map.get("executable", []) |> List.wrap()
      }
    end)
  end

  defp split_targets(target) when is_binary(target) do
    target |> String.split(" ", trim: true) |> Enum.map(&String.trim/1)
  end
end
