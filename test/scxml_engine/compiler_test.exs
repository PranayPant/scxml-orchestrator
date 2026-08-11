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

  describe "target resolution" do
    test "resolves dotted paths and leaves unresolvable ones untouched" do
      doc = %{
        "scxml" => %{
          "id" => "targets",
          "initial" => "a",
          "states" => [
            %{
              "id" => "a",
              "type" => "compound",
              "initial" => "a1",
              "transitions" => [
                %{"id" => "t1", "event" => "good", "target" => "a.a1", "executable" => []},
                %{"id" => "t2", "event" => "bad_path", "target" => "a.bogus", "executable" => []},
                %{"id" => "t3", "event" => "bad_head", "target" => "ghost.x", "executable" => []}
              ],
              "states" => [%{"id" => "a1", "metadata" => []}],
              "parallels" => [],
              "finals" => []
            }
          ],
          "parallels" => [],
          "finals" => []
        }
      }

      graph = doc |> Document.from_map() |> Compiler.compile()
      [t1, t2, t3] = graph.states["a"].transitions

      assert t1.targets == ["a1"]
      assert t2.targets == ["a.bogus"]
      assert t3.targets == ["ghost.x"]
    end
  end

  describe "store/2 and fetch/1 edge cases" do
    test "generates an id when none is provided or present" do
      graph = %ScxmlEngine.RuntimeGraph{states: %{}}
      {:ok, id} = Compiler.store(graph, nil)

      assert is_binary(id)
      assert String.starts_with?(id, "g-")
      assert Compiler.fetch(id)
    end

    test "fetch returns nil for an absent graph id" do
      assert Compiler.fetch("no_such_graph_xyz") == nil
    end

    test "compile handles a graph without a parent_map (fallback empty)" do
      graph = %ScxmlEngine.RuntimeGraph{
        states: %{"s1" => %ScxmlEngine.RuntimeState{id: "s1", type: :atomic}}
      }

      compiled = Compiler.compile(graph)
      assert compiled.parent_map == %{}
      assert compiled.ancestors_map["s1"] == []
    end
  end

  describe "event indexing" do
    test "star events are treated as patterns, not exact" do
      doc = %{
        "scxml" => %{
          "id" => "star",
          "initial" => "s",
          "states" => [
            %{
              "id" => "s",
              "type" => "atomic",
              "transitions" => [
                %{"id" => "t", "event" => "*", "target" => "s", "executable" => []}
              ],
              "metadata" => []
            }
          ],
          "parallels" => [],
          "finals" => []
        }
      }

      graph = doc |> Document.from_map() |> Compiler.compile()
      refute Map.has_key?(graph.event_index.exact, "*")
      assert Enum.any?(graph.event_index.patterns, &(&1.event == "*"))
    end

    test "graph_prefix/0 returns the persistent_term key prefix" do
      assert Compiler.graph_prefix() == :scxml_graph
    end
  end
end
