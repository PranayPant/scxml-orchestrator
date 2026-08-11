defmodule ScxmlEngine.DocumentTest do
  use ExUnit.Case, async: true

  alias ScxmlEngine.Document
  alias ScxmlEngine.RuntimeState
  alias ScxmlEngine.RuntimeTransition
  alias ScxmlEngine.TestSupport.Fixtures

  describe "from_map/1 (parser AST shape)" do
    test "ingests a flat-array document into a flat state map" do
      graph = "traffic_light" |> Fixtures.decode() |> Document.from_map()

      assert graph.id == "traffic_light"
      assert graph.initial == "red"
      assert graph.states |> Map.keys() |> Enum.sort() == ["green", "red", "yellow"]
    end

    test "derives state types from node kinds" do
      graph = "workflow" |> Fixtures.decode() |> Document.from_map()

      assert graph.states["idle"].type == :atomic
      assert graph.states["active"].type == :compound
      assert graph.states["a1"].type == :atomic
      assert graph.states["hist"].type == :history
      assert graph.states["done"].type == :final
    end

    test "records parent_map during the structural walk" do
      graph = "workflow" |> Fixtures.decode() |> Document.from_map()

      assert graph.parent_map["a1"] == "active"
      assert graph.parent_map["a2"] == "active"
      assert graph.parent_map["a3"] == "active"
      assert graph.parent_map["hist"] == "active"
      assert graph.parent_map["active"] == nil
      assert graph.parent_map["done"] == nil
    end

    test "splits multi-target transition strings into lists" do
      graph = "media_player" |> Fixtures.decode() |> Document.from_map()

      the_state = graph.states["off"]
      assert [%RuntimeTransition{targets: targets}] = the_state.transitions
      assert targets == ["both.audio", "both.video"]
    end

    test "carries lowercase onentry/onexit and executable into structs" do
      graph = "traffic_light" |> Fixtures.decode() |> Document.from_map()

      red = graph.states["red"]
      assert [%{"kind" => "assign"}] = red.on_entry

      # the red->green transition has a raise action
      [%RuntimeTransition{actions: actions} | _] = red.transitions
      assert actions == [%{"kind" => "raise", "event" => "tick"}]
    end

    test "sets history fields for history nodes" do
      graph = "workflow" |> Fixtures.decode() |> Document.from_map()
      hist = graph.states["hist"]
      assert %RuntimeState{type: :history, history_type: :shallow} = hist
    end
  end

  describe "load/1" do
    test "parses a JSON string" do
      {:ok, graph} = Document.load(Fixtures.load_json("traffic_light"))
      assert graph.initial == "red"
      assert map_size(graph.states) == 3
    end

    test "returns an error on invalid JSON" do
      assert {:error, _} = Document.load("{ not json")
    end
  end

  describe "type resolution edge cases" do
    test "final via donedata, explicit compound type, and children-derived compound" do
      doc = %{
        "scxml" => %{
          "id" => "types",
          "initial" => "a",
          "states" => [
            %{"id" => "a", "donedata" => %{"content" => []}, "metadata" => []},
            %{"id" => "b", "type" => "compound", "metadata" => []},
            %{"id" => "c", "metadata" => [], "states" => [%{"id" => "c1", "metadata" => []}]},
            %{"id" => "d", "metadata" => []}
          ],
          "parallels" => [],
          "finals" => []
        }
      }

      graph = Document.from_map(doc)

      assert graph.states["a"].type == :final
      assert graph.states["b"].type == :compound
      assert graph.states["c"].type == :compound
      assert graph.states["c1"].type == :atomic
      assert graph.states["d"].type == :atomic
    end

    test "parallel/final array hints and deep history" do
      doc = %{
        "scxml" => %{
          "id" => "kinds",
          "initial" => "p",
          "states" => [],
          "parallels" => [
            %{"id" => "p", "states" => [], "parallels" => [], "finals" => [], "metadata" => []}
          ],
          "finals" => [%{"id" => "done", "metadata" => []}],
          "history" => [%{"id" => "h", "type" => "deep"}]
        }
      }

      graph = Document.from_map(doc)

      assert graph.states["p"].type == :parallel
      assert graph.states["done"].type == :final
      assert graph.states["h"].type == :history
      assert graph.states["h"].history_type == :deep
    end

    test "history default transition targets are split" do
      doc = %{
        "scxml" => %{
          "id" => "hist",
          "initial" => "s",
          "states" => [%{"id" => "s", "metadata" => []}],
          "parallels" => [],
          "finals" => [],
          "history" => [%{"id" => "h", "transition" => %{"target" => "s s2"}}]
        }
      }

      graph = Document.from_map(doc)
      assert graph.states["h"].history_targets == ["s", "s2"]
    end

    test "raises on a non-scxml document" do
      assert_raise ArgumentError, fn -> Document.from_map(%{"foo" => "bar"}) end
    end

    test "a state node carrying a transition map is treated as history" do
      doc = %{
        "scxml" => %{
          "id" => "h2",
          "initial" => "s",
          "states" => [
            %{"id" => "s", "metadata" => []},
            %{"id" => "h2", "transition" => %{"target" => "s"}}
          ],
          "parallels" => [],
          "finals" => []
        }
      }

      graph = Document.from_map(doc)
      assert graph.states["h2"].type == :history
    end
  end
end
