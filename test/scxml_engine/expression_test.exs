defmodule ScxmlEngine.ExpressionTest do
  use ExUnit.Case, async: true

  alias ScxmlEngine.Expression

  describe "evaluate/2" do
    test "arithmetic" do
      assert Expression.evaluate("1 + 2 * 3", %{}) == {:ok, 7}
      assert Expression.evaluate("(1 + 2) * 3", %{}) == {:ok, 9}
      assert Expression.evaluate("10 / 2", %{}) == {:ok, 5.0}
      assert Expression.evaluate("-5", %{}) == {:ok, -5}
    end

    test "comparisons" do
      assert Expression.evaluate("data.amount > 100", %{"data" => %{"amount" => 150}}) ==
               {:ok, true}

      assert Expression.evaluate("data.amount > 100", %{"data" => %{"amount" => 50}}) ==
               {:ok, false}

      assert Expression.evaluate("3 <= 3", %{}) == {:ok, true}
    end

    test "boolean logic" do
      assert Expression.evaluate("true and false", %{}) == {:ok, false}
      assert Expression.evaluate("true or false", %{}) == {:ok, true}
      assert Expression.evaluate("not false", %{}) == {:ok, true}
    end

    test "string literals and equality" do
      assert Expression.evaluate("data.color == \"red\"", %{"data" => %{"color" => "red"}}) ==
               {:ok, true}

      assert Expression.evaluate("'a' == \"a\"", %{}) == {:ok, true}
    end

    test "dotted path resolution with missing keys" do
      assert Expression.evaluate("data.missing", %{"data" => %{}}) == {:ok, :undef}
      assert Expression.evaluate("x", %{"x" => 42}) == {:ok, 42}
    end

    test "guard_true?/2" do
      assert Expression.guard_true?(nil, %{})
      assert Expression.guard_true?("data.amount > 10", %{"data" => %{"amount" => 20}})
      refute Expression.guard_true?("data.amount > 10", %{"data" => %{"amount" => 5}})
      refute Expression.guard_true?("10 / 0", %{})
    end
  end
end
