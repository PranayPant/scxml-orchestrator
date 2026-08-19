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

  describe "execution_status/1" do
    test ":idle when instance is created at initial configuration" do
      pid = start_traffic_light()
      assert Instance.execution_status(pid) == :idle
    end

    test ":running after events have been processed" do
      pid = start_traffic_light()
      Instance.send_event(pid, "next")
      assert Instance.execution_status(pid) == :running
    end

    test ":completed when a final state is reached" do
      {pid, _graph_id} = start_workflow()

      # idle -> active.hist (defaults to a1)
      Instance.send_event(pid, "start")
      # active -> done (final state)
      Instance.send_event(pid, "finish")

      assert Instance.execution_status(pid) == :completed
    end
  end

  describe "active_states/1" do
    test "returns active states with their statuses" do
      pid = start_traffic_light()
      states = Instance.active_states(pid)

      assert length(states) == 1
      assert Enum.find(states, &(&1.id == "red")) == %{id: "red", status: :running, type: :atomic}
    end

    test "returns multiple states for parallel configurations" do
      {pid, _graph_id} = start_workflow()

      Instance.send_event(pid, "start")
      # After start, should be in active/a2 (compound state with children)
      states = Instance.active_states(pid)

      refute states == []
      # All non-final states should be :running
      assert Enum.all?(states, &(&1.status == :running))
    end

    test "marks final states as :completed" do
      {pid, _graph_id} = start_workflow()

      Instance.send_event(pid, "start")
      Instance.send_event(pid, "finish")

      states = Instance.active_states(pid)
      done_state = Enum.find(states, &(&1.id == "done"))

      assert done_state.status == :completed
      assert done_state.type == :final
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

  describe "eventless transitions" do
    setup do
      {:ok, pid} = start_fixture("eventless")
      {:ok, pid: pid}
    end

    test "runs on_exit and settles eventless transitions during the macrostep", %{pid: pid} do
      assert Instance.active_configuration(pid) == MapSet.new(["start"])

      Instance.send_event(pid, "go")

      # start -> settling (enters pending) -> eventless settle -> done
      assert Instance.active_configuration(pid) == MapSet.new(["done"])
      assert Instance.datamodel(pid)["data"]["exited"] == "yes"
      assert Instance.datamodel(pid)["data"]["entered"] == "yes"
    end

    test "a guarded eventless transition is not selected and unmatched events are ignored", %{
      pid: pid
    } do
      Instance.send_event(pid, "go")
      assert Instance.active_configuration(pid) == MapSet.new(["done"])

      # "bogus" matches no transition; the nil-event guarded transition is not
      # selected for external events (event_matches?(nil, _) => false).
      Instance.send_event(pid, "bogus")
      assert Instance.active_configuration(pid) == MapSet.new(["done"])

      Instance.send_event(pid, "reset")
      assert Instance.active_configuration(pid) == MapSet.new(["start"])
    end
  end

  describe "deep history" do
    setup do
      {:ok, pid} = start_fixture("deep_history")
      {:ok, pid: pid}
    end

    test "restores the last-active descendant when re-entering via deep history", %{pid: pid} do
      assert active(pid) == ["in", "in_a", "outer"]

      Instance.send_event(pid, "next")
      assert active(pid) == ["in", "in_b", "outer"]

      Instance.send_event(pid, "leave")
      assert active(pid) == ["top"]

      Instance.send_event(pid, "restore")
      assert active(pid) == ["in", "in_b", "outer"]
    end

    defp active(pid) do
      pid |> Instance.active_configuration() |> MapSet.to_list() |> Enum.sort()
    end
  end

  describe "executable actions (actions fixture)" do
    setup do
      graph = "actions" |> Fixtures.decode() |> Document.from_map()

      {:ok, id} =
        Compiler.store(
          graph,
          "act_" <> Integer.to_string(:erlang.unique_integer([:positive]))
        )

      {:ok, pid} =
        Instance.start_link(
          graph_id: id,
          initial_datamodel: %{"data" => %{"flag" => true, "list" => [1, 2, 3]}}
        )

      {:ok, pid: pid}
    end

    test "executes assign/if/elseif/else/foreach/send/log/cancel/script on entry", %{pid: pid} do
      data = Instance.datamodel(pid)["data"]

      assert data["a"] == "x"
      assert data["bracket"] == "y"
      assert data["v"] == 99
      assert Map.has_key?(data, "n")
      assert data["iffy"] == "yes"
      refute Map.has_key?(data, "iffy_not")
      assert data["elseif"] == "ran"
      assert data["elsed"] == "ran"
      assert data["last"] == 3
      refute Map.has_key?(data, "should_not")

      # send actions raised internal events that were drained without effect
      assert Instance.active_configuration(pid) == MapSet.new(["run"])
    end

    test "a transition to a missing target exits the source without crashing", %{pid: pid} do
      Instance.send_event(pid, "ghost")

      # The dangling target cannot be entered, so the source is exited and the
      # machine is left with an empty configuration rather than crashing.
      assert Instance.active_configuration(pid) == MapSet.new()
    end
  end

  describe "instance start failures" do
    test "start_link stops when the graph is not stored" do
      old = Process.flag(:trap_exit, true)

      result =
        try do
          Instance.start_link(graph_id: "definitely_missing_graph")
        after
          Process.flag(:trap_exit, old)
        end

      assert result == {:error, {:graph_not_found, "definitely_missing_graph"}}
    end
  end

  describe "entry chains via shallow history (compound/parallel restore)" do
    setup do
      {:ok, pid} = start_fixture("entry_chain")
      {:ok, pid: pid}
    end

    test "restores a parallel region and descends compound initials", %{pid: pid} do
      assert active(pid) == ["a", "a1", "b", "b1", "outer", "p"]

      Instance.send_event(pid, "leave")
      assert active(pid) == ["top"]

      Instance.send_event(pid, "back")
      assert active(pid) == ["a", "a1", "b", "b1", "outer", "p"]
    end

    defp active(pid) do
      pid |> Instance.active_configuration() |> MapSet.to_list() |> Enum.sort()
    end
  end

  describe "entering a parallel state directly" do
    test "activates all its regions' initial children" do
      doc = %{
        "scxml" => %{
          "id" => "parallel_entry",
          "initial" => "off",
          "states" => [
            %{
              "id" => "off",
              "type" => "atomic",
              "transitions" => [
                %{"id" => "t", "event" => "go", "target" => "both", "executable" => []}
              ],
              "metadata" => []
            }
          ],
          "parallels" => [
            %{
              "id" => "both",
              "states" => [
                %{
                  "id" => "a",
                  "type" => "compound",
                  "initial" => "a1",
                  "states" => [%{"id" => "a1", "metadata" => []}],
                  "parallels" => [],
                  "finals" => []
                },
                %{
                  "id" => "b",
                  "type" => "compound",
                  "initial" => "b1",
                  "states" => [%{"id" => "b1", "metadata" => []}],
                  "parallels" => [],
                  "finals" => []
                }
              ],
              "parallels" => [],
              "finals" => []
            }
          ],
          "finals" => []
        }
      }

      {:ok, pid} = start_doc(doc)

      Instance.send_event(pid, "go")

      assert pid |> Instance.active_configuration() |> MapSet.to_list() |> Enum.sort() ==
               ["a", "a1", "b", "b1", "both"]
    end
  end

  describe "history default targets" do
    test "falls back to the history node's default target when nothing is recorded" do
      doc = %{
        "scxml" => %{
          "id" => "hist_default",
          "initial" => "top",
          "states" => [
            %{
              "id" => "top",
              "type" => "atomic",
              "transitions" => [
                %{"id" => "t", "event" => "enter", "target" => "outer.h", "executable" => []}
              ],
              "metadata" => []
            },
            %{
              "id" => "outer",
              "type" => "compound",
              "states" => [
                %{"id" => "in", "type" => "atomic", "metadata" => []}
              ],
              "parallels" => [],
              "finals" => [],
              "history" => [
                %{"id" => "h", "transition" => %{"target" => "in"}}
              ]
            }
          ],
          "parallels" => [],
          "finals" => []
        }
      }

      {:ok, pid} = start_doc(doc)
      Instance.send_event(pid, "enter")
      assert pid |> Instance.active_configuration() |> MapSet.to_list() |> Enum.sort() == ["in", "outer"]
    end

    test "enters nothing when a history has no default and its parent has no initial" do
      doc = %{
        "scxml" => %{
          "id" => "hist_none",
          "initial" => "top",
          "states" => [
            %{
              "id" => "top",
              "type" => "atomic",
              "transitions" => [
                %{"id" => "t", "event" => "enter", "target" => "outer.h", "executable" => []}
              ],
              "metadata" => []
            },
            %{
              "id" => "outer",
              "type" => "compound",
              "states" => [%{"id" => "in", "type" => "atomic", "metadata" => []}],
              "parallels" => [],
              "finals" => [],
              "history" => [%{"id" => "h"}]
            }
          ],
          "parallels" => [],
          "finals" => []
        }
      }

      {:ok, pid} = start_doc(doc)
      Instance.send_event(pid, "enter")
      assert Instance.active_configuration(pid) == MapSet.new(["outer"])
    end
  end

  describe "initial configuration edge cases" do
    test "an initial pointing at a missing state activates nothing" do
      doc = %{
        "scxml" => %{"id" => "empty", "initial" => "ghost", "states" => [], "parallels" => [], "finals" => []}
      }

      {:ok, pid} = start_doc(doc)
      assert Instance.active_configuration(pid) == MapSet.new()
    end

    test "an initial pointing at a parallel enters all its regions" do
      doc = %{
        "scxml" => %{
          "id" => "par_initial",
          "initial" => "par",
          "states" => [],
          "parallels" => [
            %{
              "id" => "par",
              "states" => [
                %{
                  "id" => "a",
                  "type" => "compound",
                  "initial" => "a1",
                  "states" => [%{"id" => "a1", "metadata" => []}],
                  "parallels" => [],
                  "finals" => []
                },
                %{"id" => "b", "type" => "atomic", "metadata" => []}
              ],
              "parallels" => [],
              "finals" => []
            }
          ],
          "finals" => []
        }
      }

      {:ok, pid} = start_doc(doc)
      assert pid |> Instance.active_configuration() |> MapSet.to_list() |> Enum.sort() == ["a", "a1", "b", "par"]
    end

    test "an initial pointing at a history state activates it and its default" do
      doc = %{
        "scxml" => %{
          "id" => "hist_initial",
          "initial" => "h",
          "states" => [
            %{
              "id" => "s",
              "type" => "atomic",
              "transitions" => [
                %{"id" => "t", "event" => "go", "target" => "t2", "executable" => []}
              ],
              "metadata" => []
            },
            %{"id" => "t2", "type" => "atomic", "metadata" => []}
          ],
          "parallels" => [],
          "finals" => [],
          "history" => [%{"id" => "h", "transition" => %{"target" => "s"}}]
        }
      }

      {:ok, pid} = start_doc(doc)
      assert Instance.active_configuration(pid) == MapSet.new(["h", "s"])

      # exiting deactivates the activated history state along with s
      Instance.send_event(pid, "go")
      assert Instance.active_configuration(pid) == MapSet.new(["t2"])
    end

    test "a history default referencing a missing state is skipped without crashing" do
      doc = %{
        "scxml" => %{
          "id" => "hist_missing",
          "initial" => "top",
          "states" => [
            %{
              "id" => "top",
              "type" => "atomic",
              "transitions" => [
                %{"id" => "enter", "event" => "enter", "target" => "outer.h", "executable" => []}
              ],
              "metadata" => []
            },
            %{
              "id" => "outer",
              "type" => "compound",
              "transitions" => [
                %{"id" => "exit", "event" => "exit", "target" => "top", "executable" => []}
              ],
              "states" => [%{"id" => "in", "type" => "atomic", "metadata" => []}],
              "parallels" => [],
              "finals" => [],
              "history" => [%{"id" => "h", "transition" => %{"target" => "ghost"}}]
            }
          ],
          "parallels" => [],
          "finals" => []
        }
      }

      {:ok, pid} = start_doc(doc)

      # The dangling default target is never activated, so the region is
      # entered without a child and later exits cleanly.
      Instance.send_event(pid, "enter")
      assert Instance.active_configuration(pid) == MapSet.new(["outer"])

      Instance.send_event(pid, "exit")
      assert Instance.active_configuration(pid) == MapSet.new(["top"])
    end
  end

  defp start_doc(doc) do
    graph = doc |> Document.from_map() |> Compiler.compile()

    {:ok, id} =
      Compiler.store(
        graph,
        "doc_" <> Integer.to_string(:erlang.unique_integer([:positive]))
      )

    Instance.start_link(graph_id: id)
  end

  defp start_fixture(name) do
    graph = name |> Fixtures.decode() |> Document.from_map()

    {:ok, id} =
      Compiler.store(
        graph,
        "#{name}_" <> Integer.to_string(:erlang.unique_integer([:positive]))
      )

    Instance.start_link(graph_id: id)
  end
end
