defmodule ScxmlEngine.CompilerTest do
  use ExUnit.Case, async: false

  alias ScxmlEngine.Compiler
  alias ScxmlEngine.Document
  alias ScxmlEngine.RuntimeTransition
  alias ScxmlEngine.TestSupport.Fixtures

  describe "compile/1" do
    test "builds parent_map and ancestors_map" do
      graph = "workflow" |> Fixtures.decode() |> Document.from_map() |> Compiler.compile()

      assert graph.parent_map["a2"] == "active"
      assert graph.ancestors_map["a2"] == ["active"]
      assert graph.ancestors_map["active"] == []
      assert graph.ancestors_map["a1"] == ["active"]
    end

    test "populates event_index" do
      graph = "traffic_light" |> Fixtures.decode() |> Document.from_map() |> Compiler.compile()

      # "next" is an exact event; it should be in the exact map.
      assert is_map(graph.event_index.exact)
      assert map_size(graph.event_index.exact) > 0
    end
  end

  describe "compute_transition_path/4 (LCA)" do
    setup do
      graph = "workflow" |> Fixtures.decode() |> Document.from_map() |> Compiler.compile()
      {:ok, graph: graph}
    end

    test "returns empty sets for an internal (target-less) transition" do
      assert Compiler.compute_transition_path(%RuntimeTransition{targets: []}, "a1", %{}, %{}) ==
               {[], [], nil}
    end

    test "computes exit/entry for sibling transitions within a compound" do
      # a1 -> a2 : both children of `active`; LCA = active.
      {exit_set, entry_set, lca} =
        Compiler.compute_transition_path(
          %RuntimeTransition{targets: ["a2"]},
          "a1",
          %{},
          %{"a1" => ["active"], "a2" => ["active"], "active" => []}
        )

      assert exit_set == ["a1"]
      assert entry_set == ["a2"]
      assert lca == "active"
    end

    test "exits ancestors up to (excluding) LCA for cross-branch transitions" do
      # a2 -> idle : LCA is the root (workflow has none, so idle is root).
      ancestors = %{
        "a2" => ["active"],
        "active" => [],
        "idle" => []
      }

      {exit_set, entry_set, lca} =
        Compiler.compute_transition_path(
          %RuntimeTransition{targets: ["idle"]},
          "active",
          %{},
          ancestors
        )

      assert exit_set == ["active"]
      assert entry_set == ["idle"]
      assert lca == nil
    end
  end

  describe "store/2 and fetch/1" do
    test "stores a compiled graph in persistent_term and fetches it back" do
      graph = "traffic_light" |> Fixtures.decode() |> Document.from_map()
      {:ok, id} = Compiler.store(graph, "test_graph_1")

      assert {:ok, stored} = fetch_graph(id)
      assert stored.initial == "red"
    end

    defp fetch_graph(id) do
      case Compiler.fetch(id) do
        nil -> {:error, :not_found}
        graph -> {:ok, graph}
      end
    end
  end
end
