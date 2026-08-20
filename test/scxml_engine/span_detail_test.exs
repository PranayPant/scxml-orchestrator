defmodule ScxmlEngine.SpanDetailTest do
  use ExUnit.Case, async: false

  alias ScxmlEngine.SpanDetail

  describe "debug?/0" do
    test "is false by default (info detail)" do
      # Ensure a clean slate regardless of the test runner order.
      Application.put_env(:scxml_orchestrator, :span_detail, :info)
      refute SpanDetail.debug?()
    end

    test "is true when span_detail is :debug" do
      Application.put_env(:scxml_orchestrator, :span_detail, :debug)
      assert SpanDetail.debug?()
      Application.put_env(:scxml_orchestrator, :span_detail, :info)
    end
  end

  describe "with_debug_span/2" do
    test "runs the block and returns its result at info detail" do
      Application.put_env(:scxml_orchestrator, :span_detail, :info)

      assert SpanDetail.with_debug_span("some.span", fn -> {:ok, 42} end) == {:ok, 42}
    end

    test "runs the block and returns its result at debug detail" do
      Application.put_env(:scxml_orchestrator, :span_detail, :debug)

      assert SpanDetail.with_debug_span("some.span", fn -> :hello end) == :hello
      Application.put_env(:scxml_orchestrator, :span_detail, :info)
    end
  end
end
