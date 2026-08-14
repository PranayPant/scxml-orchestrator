defmodule ScxmlEngine.OrchestratorTest do
  use ExUnit.Case, async: false

  alias ScxmlEngine.Compiler
  alias ScxmlEngine.TestSupport.Fixtures

  @moduletag timeout: 5000

  describe "ScxmlOrchestrator facade" do
    test "load/store/start/drive through the facade" do
      json = Fixtures.load_json("traffic_light")

      assert {:ok, graph} = ScxmlOrchestrator.load(json)
      assert {:ok, id} = ScxmlOrchestrator.store(graph, "facade_graph")

      assert {:ok, pid} =
               ScxmlOrchestrator.start_instance(graph_id: id, instance_id: "facade_1")

      assert ScxmlOrchestrator.active_configuration(pid) == MapSet.new(["red"])

      ScxmlOrchestrator.send_event(pid, "next")
      assert ScxmlOrchestrator.active_configuration(pid) == MapSet.new(["green"])
      assert ScxmlOrchestrator.datamodel(pid)["data"]["color"] == "green"
      refute ScxmlOrchestrator.done?(pid)

      assert {:ok, _} = ScxmlOrchestrator.instance_pid("facade_1")
      assert Enum.any?(ScxmlOrchestrator.instances(), fn {i, _} -> i == "facade_1" end)
    end

    test "run/2 convenience wraps load+store+start" do
      json = Fixtures.load_json("traffic_light")
      assert {:ok, pid} = ScxmlOrchestrator.run(json, instance_id: "facade_run")
      assert ScxmlOrchestrator.active_configuration(pid) == MapSet.new(["red"])
    end

    test "send_event_to/3 routes through the facade" do
      json = Fixtures.load_json("traffic_light")
      {:ok, _pid} = ScxmlOrchestrator.run(json, instance_id: "facade_route")
      assert :ok = ScxmlOrchestrator.send_event_to("facade_route", "next")
      assert {:ok, pid} = ScxmlOrchestrator.instance_pid("facade_route")
      assert ScxmlOrchestrator.active_configuration(pid) == MapSet.new(["green"])
    end
  end

  describe "ScxmlEngine facade edge cases" do
    test "send_event_to/instance_pid return :error for unknown instance ids" do
      assert ScxmlEngine.send_event_to("does_not_exist_xyz", "next") == :error
      assert ScxmlEngine.instance_pid("does_not_exist_xyz") == :error
    end

    test "done? is true when the active configuration is empty" do
      json = ~s({"scxml": {"id": "empty", "states": [], "parallels": [], "finals": []}})
      {:ok, pid} = ScxmlEngine.run(json, instance_id: "empty_1")

      assert ScxmlEngine.active_configuration(pid) == MapSet.new()
      assert ScxmlEngine.done?(pid) == true
    end

    test "run with an explicit graph_id and start_instance against it" do
      json = Fixtures.load_json("traffic_light")
      {:ok, pid} = ScxmlEngine.run(json, graph_id: "explicit_g", instance_id: "explicit_1")
      assert ScxmlEngine.active_configuration(pid) == MapSet.new(["red"])

      # a second instance can be started against the same stored graph
      assert {:ok, pid2} =
               ScxmlEngine.start_instance(graph_id: "explicit_g", instance_id: "explicit_2")

      assert ScxmlEngine.active_configuration(pid2) == MapSet.new(["red"])
    end

    test "ScxmlEngine load/store/run are exercised directly (both arities)" do
      json = Fixtures.load_json("traffic_light")
      assert {:ok, graph} = ScxmlEngine.load(json)

      # 1-arity (default-arg) forms
      assert {:ok, id1} = ScxmlEngine.store(graph)
      assert {:ok, pid1} = ScxmlEngine.run(json)
      assert Compiler.fetch(id1)
      assert ScxmlEngine.active_configuration(pid1) == MapSet.new(["red"])

      # 2-arity (explicit) forms
      assert {:ok, id2} = ScxmlEngine.store(graph, "direct_store_g")
      assert {:ok, pid2} = ScxmlEngine.run(json, graph_id: "direct_run_g", instance_id: "direct_run")
      assert Compiler.fetch(id2)
      assert ScxmlEngine.active_configuration(pid2) == MapSet.new(["red"])
    end
  end

  describe "execution_status/1 via ScxmlOrchestrator" do
    test "starts as :idle before any external event" do
      json = Fixtures.load_json("traffic_light")
      {:ok, pid} = ScxmlOrchestrator.run(json, instance_id: "orch_exec_1")
      assert ScxmlOrchestrator.execution_status(pid) == :idle
    end

    test "becomes :running after receiving an external event" do
      json = Fixtures.load_json("traffic_light")
      {:ok, pid} = ScxmlOrchestrator.run(json, instance_id: "orch_exec_2")
      ScxmlOrchestrator.send_event(pid, "next")
      assert ScxmlOrchestrator.execution_status(pid) == :running
    end
  end

  describe "active_states/1 via ScxmlOrchestrator" do
    test "returns state_info maps with id, status, type" do
      json = Fixtures.load_json("traffic_light")
      {:ok, pid} = ScxmlOrchestrator.run(json, instance_id: "orch_active_1")

      states = ScxmlOrchestrator.active_states(pid)
      assert is_list(states)
      red = Enum.find(states, &(&1.id == "red"))
      assert red.status == :running
      assert red.type == :atomic
    end

    test "reflects state changes after events" do
      json = Fixtures.load_json("traffic_light")
      {:ok, pid} = ScxmlOrchestrator.run(json, instance_id: "orch_active_2")

      ScxmlOrchestrator.send_event(pid, "next")
      states = ScxmlOrchestrator.active_states(pid)
      assert Enum.find(states, &(&1.id == "green"))
      refute Enum.find(states, &(&1.id == "red"))
    end
  end
end
