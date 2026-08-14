defmodule ScxmlEngine.EngineTest do
  use ExUnit.Case, async: false

  alias ScxmlEngine.TestSupport.Fixtures

  @moduletag timeout: 5000

  describe "ScxmlEngine.run/2 full pipeline" do
    test "loads, stores, starts, and drives an instance through the public API" do
      json = Fixtures.load_json("traffic_light")
      {:ok, pid} = ScxmlEngine.run(json, instance_id: "traffic_1")

      assert pid |> ScxmlEngine.active_configuration() |> MapSet.to_list() == ["red"]
      ScxmlEngine.send_event(pid, "next")
      assert ScxmlEngine.active_configuration(pid) == MapSet.new(["green"])
      assert ScxmlEngine.done?(pid) == false
    end

    test "registers the instance by instance_id for lookup" do
      json = Fixtures.load_json("traffic_light")
      {:ok, _pid} = ScxmlEngine.run(json, instance_id: "traffic_registry")

      assert {:ok, _pid} = ScxmlEngine.instance_pid("traffic_registry")
      assert Enum.any?(ScxmlEngine.instances(), fn {id, _} -> id == "traffic_registry" end)
    end

    test "send_event_to/3 routes events to a registered instance" do
      json = Fixtures.load_json("traffic_light")
      {:ok, _pid} = ScxmlEngine.run(json, instance_id: "traffic_route")

      assert :ok = ScxmlEngine.send_event_to("traffic_route", "next")
      assert {:ok, pid} = ScxmlEngine.instance_pid("traffic_route")
      assert ScxmlEngine.active_configuration(pid) == MapSet.new(["green"])
    end
  end

  describe "parallel regions (media_player)" do
    setup do
      unique = :erlang.unique_integer([:positive])
      json = Fixtures.load_json("media_player")
      {:ok, pid} = ScxmlEngine.run(json, instance_id: "media_#{unique}", initial_datamodel: %{})
      {:ok, pid: pid}
    end

    test "starts in the off state before powering on", %{pid: pid} do
      active = pid |> ScxmlEngine.active_configuration() |> MapSet.to_list() |> Enum.sort()
      assert active == ["off", "player"]
    end

    test "powering on enters both parallel regions and their initial children", %{pid: pid} do
      ScxmlEngine.send_event(pid, "power")

      active = pid |> ScxmlEngine.active_configuration() |> MapSet.to_list() |> Enum.sort()
      assert active == ["audio", "audio_idle", "both", "player", "video", "video_idle"]
    end

    test "play/pause drives both regions independently", %{pid: pid} do
      ScxmlEngine.send_event(pid, "power")
      ScxmlEngine.send_event(pid, "play")

      active = pid |> ScxmlEngine.active_configuration() |> MapSet.to_list() |> Enum.sort()
      assert active == ["audio", "audio_playing", "both", "player", "video", "video_playing"]

      ScxmlEngine.send_event(pid, "pause")
      active = pid |> ScxmlEngine.active_configuration() |> MapSet.to_list() |> Enum.sort()
      assert active == ["audio", "audio_idle", "both", "player", "video", "video_idle"]
    end
  end

  describe "execution_status/1" do
    test "starts as :idle before any external event" do
      json = Fixtures.load_json("traffic_light")
      {:ok, pid} = ScxmlEngine.run(json, instance_id: "exec_status_1")
      assert ScxmlEngine.execution_status(pid) == :idle
    end

    test "becomes :running after receiving an external event" do
      json = Fixtures.load_json("traffic_light")
      {:ok, pid} = ScxmlEngine.run(json, instance_id: "exec_status_2")
      ScxmlEngine.send_event(pid, "next")
      assert ScxmlEngine.execution_status(pid) == :running
    end
  end

  describe "active_states/1" do
    test "returns a list of state_info maps with id, status, type" do
      json = Fixtures.load_json("traffic_light")
      {:ok, pid} = ScxmlEngine.run(json, instance_id: "active_states_1")

      states = ScxmlEngine.active_states(pid)
      assert is_list(states)
      red = Enum.find(states, &(&1.id == "red"))
      assert red.status == :running
      assert red.type == :atomic
    end

    test "reflects state changes after sending events" do
      json = Fixtures.load_json("traffic_light")
      {:ok, pid} = ScxmlEngine.run(json, instance_id: "active_states_2")

      ScxmlEngine.send_event(pid, "next")
      states = ScxmlEngine.active_states(pid)
      assert Enum.find(states, &(&1.id == "green"))
      refute Enum.find(states, &(&1.id == "red"))
    end

    test "returns empty list when no active states" do
      json = ~s({"scxml": {"id": "empty", "states": [], "parallels": [], "finals": []}})
      {:ok, pid} = ScxmlEngine.run(json, instance_id: "active_states_empty")
      assert ScxmlEngine.active_states(pid) == []
    end
  end
end
