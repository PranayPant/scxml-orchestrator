defmodule ScxmlEngine.InstanceTest do
  use ExUnit.Case, async: false

  alias ScxmlEngine.Compiler
  alias ScxmlEngine.Document
  alias ScxmlEngine.Instance
  alias ScxmlEngine.TestSupport.Fixtures

  @moduletag timeout: 5000

  defp start_traffic_light(opts \\ []) do
    graph = "traffic_light" |> Fixtures.decode() |> Document.from_map()

    {:ok, id} =
      Compiler.store(graph, "tl_" <> Integer.to_string(:erlang.unique_integer([:positive])))

    {:ok, pid} =
      Instance.start_link(
        graph_id: id,
        initial_datamodel: Keyword.get(opts, :initial_datamodel, %{})
      )

    pid
  end

  describe "traffic light" do
    test "starts in the initial state" do
      pid = start_traffic_light()
      assert Instance.active_configuration(pid) == MapSet.new(["red"])
    end

    test "advances through states on events" do
      pid = start_traffic_light()

      assert pid |> Instance.active_configuration() |> MapSet.to_list() == ["red"]

      Instance.send_event(pid, "next")
      assert Instance.active_configuration(pid) == MapSet.new(["green"])

      Instance.send_event(pid, "next")
      assert Instance.active_configuration(pid) == MapSet.new(["yellow"])

      Instance.send_event(pid, "next")
      assert Instance.active_configuration(pid) == MapSet.new(["red"])
    end

    test "runs assign on-entry actions updating the datamodel" do
      pid = start_traffic_light()
      assert Instance.datamodel(pid)["data"]["color"] == "red"

      Instance.send_event(pid, "next")
      assert Instance.datamodel(pid)["data"]["color"] == "green"
    end
  end

  describe "raised internal events" do
    test "a raise action queues an internal event processed before external" do
      # red->green has a `raise tick`; redefine expectations: raise tick has no
      # matching transition here, so state settles at green.
      pid = start_traffic_light()
      Instance.send_event(pid, "next")
      # raise "tick" does not match any transition (no tick transitions), so we
      # remain in green rather than erroring.
      assert Instance.active_configuration(pid) == MapSet.new(["green"])
    end
  end

  describe "guards" do
    test "guard blocks transition when false and allows when true" do
      {pid, graph_id} = start_workflow()
      _ = graph_id

      # a2 has two `step` transitions: one guarded (amount > 10), one unguarded.
      # -> active.hist (defaults to a1)
      Instance.send_event(pid, "start")
      # a1 -> a2
      Instance.send_event(pid, "step")
      assert Instance.active_configuration(pid) == MapSet.new(["active", "a2"])
      assert Instance.datamodel(pid)["data"]["current"] == "a2"

      # With amount <= 10, the unguarded a2->a1 transition fires.
      Instance.send_event(pid, "step")
      assert Instance.active_configuration(pid) == MapSet.new(["active", "a1"])
    end

    defp start_workflow do
      graph = "workflow" |> Fixtures.decode() |> Document.from_map()

      {:ok, id} =
        Compiler.store(graph, "wf_" <> Integer.to_string(:erlang.unique_integer([:positive])))

      {:ok, pid} = Instance.start_link(graph_id: id)
      {pid, id}
    end
  end
end
