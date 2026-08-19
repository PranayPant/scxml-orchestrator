defmodule ScxmlEngine.SpanAttrsTest do
  use ExUnit.Case, async: true

  alias ScxmlEngine.SpanAttrs

  describe "config_to_string/1" do
    test "joins a sorted state-id list with commas" do
      assert SpanAttrs.config_to_string(["idle", "running"]) == "idle,running"
    end

    test "returns an empty string for an empty list" do
      assert SpanAttrs.config_to_string([]) == ""
    end

    test "falls back to inspect for non-list values" do
      assert SpanAttrs.config_to_string(%{custom: :value}) == "%{custom: :value}"
    end
  end

  describe "target_to_string/1" do
    test "joins target ids with commas" do
      assert SpanAttrs.target_to_string(["running", "finished"]) == "running,finished"
    end

    test "falls back to inspect for non-list values" do
      assert SpanAttrs.target_to_string(:single) == ":single"
    end
  end

  describe "enabled_transition_to_string/1" do
    test "renders a from/event/targets transition as a readable arrow string" do
      transition = %ScxmlEngine.RuntimeTransition{
        event: "done",
        targets: ["finished"]
      }

      assert SpanAttrs.enabled_transition_to_string({"processing", transition}) ==
               "processing ->done-> finished"
    end

    test "renders empty-event and multi-target transitions" do
      transition = %ScxmlEngine.RuntimeTransition{
        event: nil,
        targets: ["a", "b"]
      }

      assert SpanAttrs.enabled_transition_to_string({"idle", transition}) == "idle ->-> a,b"
    end
  end
end
