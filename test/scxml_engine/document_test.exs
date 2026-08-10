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
end
