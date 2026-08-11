defmodule ScxmlEngine.ExpressionTest do
  use ExUnit.Case, async: true

  alias ScxmlEngine.Expression
  alias ScxmlEngine.Expression.Evaluator
  alias ScxmlEngine.Expression.Parser
  alias ScxmlEngine.Expression.Tokenizer

  describe "evaluate/2 — arithmetic" do
    test "add/mul/sub/div with precedence and parens" do
      assert Expression.evaluate("1 + 2 * 3", %{}) == {:ok, 7}
      assert Expression.evaluate("(1 + 2) * 3", %{}) == {:ok, 9}
      assert Expression.evaluate("10 / 2", %{}) == {:ok, 5.0}
      assert Expression.evaluate("7 - 2", %{}) == {:ok, 5}
    end

    test "unary minus, modulo, and float literals" do
      assert Expression.evaluate("-5", %{}) == {:ok, -5}
      assert Expression.evaluate("10 % 3", %{}) == {:ok, 1}
      assert Expression.evaluate("1.5 + 1", %{}) == {:ok, 2.5}
    end

    test "string concatenation via +" do
      assert Expression.evaluate("'a' + 'b'", %{}) == {:ok, "ab"}
    end

    test "precedence early-exit in the parser" do
      assert Expression.evaluate("1 * 2 + 3", %{}) == {:ok, 5}
    end
  end

  describe "evaluate/2 — comparisons" do
    test "all six operators" do
      assert Expression.evaluate("1 < 2", %{}) == {:ok, true}
      assert Expression.evaluate("2 <= 2", %{}) == {:ok, true}
      assert Expression.evaluate("3 > 2", %{}) == {:ok, true}
      assert Expression.evaluate("3 >= 4", %{}) == {:ok, false}
      assert Expression.evaluate("1 == 1", %{}) == {:ok, true}
      assert Expression.evaluate("1 != 2", %{}) == {:ok, true}
    end
  end

  describe "evaluate/2 — boolean logic" do
    test "and/or/not plus symbol forms" do
      assert Expression.evaluate("true and false", %{}) == {:ok, false}
      assert Expression.evaluate("true or false", %{}) == {:ok, true}
      assert Expression.evaluate("not false", %{}) == {:ok, true}
      assert Expression.evaluate("true && false", %{}) == {:ok, false}
      assert Expression.evaluate("true || false", %{}) == {:ok, true}
      assert Expression.evaluate("!true", %{}) == {:ok, false}
    end

    test "boolean ops apply truthiness to non-boolean operands" do
      assert Expression.evaluate("0 and true", %{}) == {:ok, false}
      assert Expression.evaluate("5 and true", %{}) == {:ok, true}
      assert Expression.evaluate("'hi' and true", %{}) == {:ok, true}
      assert Expression.evaluate("'' and true", %{}) == {:ok, false}
      assert Expression.evaluate("not 0", %{}) == {:ok, true}
      assert Expression.evaluate("not nil", %{}) == {:ok, true}
      assert Expression.evaluate("data.x and true", %{"data" => %{"x" => nil}}) == {:ok, false}
      assert Expression.evaluate("data.m and true", %{"data" => %{}}) == {:ok, false}
      assert Expression.evaluate("data.o or false", %{"data" => %{"o" => %{}}}) == {:ok, true}
    end
  end

  describe "evaluate/2 — strings and paths" do
    test "string literals and equality" do
      assert Expression.evaluate("data.color == \"red\"", %{"data" => %{"color" => "red"}}) ==
               {:ok, true}

      assert Expression.evaluate("'a' == \"a\"", %{}) == {:ok, true}
    end

    test "dotted and bracketed access" do
      dm = %{"data" => %{"color" => "red", "list" => [10, 20], "nested" => %{"deep" => 5}}}

      assert Expression.evaluate("data.color", dm) == {:ok, "red"}
      assert Expression.evaluate("data[\"color\"]", dm) == {:ok, "red"}
      assert Expression.evaluate("data['color']", dm) == {:ok, "red"}
      assert Expression.evaluate("data.list[1]", dm) == {:ok, 20}
      assert Expression.evaluate("data.list[9]", dm) == {:ok, :undef}
      assert Expression.evaluate(~s(data["nested"]["deep"]), dm) == {:ok, 5}
    end

    test "non-data top-level path resolution" do
      assert Expression.evaluate("x.y", %{"x" => %{"y" => 7}}) == {:ok, 7}
      assert Expression.evaluate("x.y.z", %{"x" => %{"y" => %{"z" => 1}}}) == {:ok, 1}
      assert Expression.evaluate("x.y", %{"x" => 5}) == {:ok, :undef}
      assert Expression.evaluate("x", %{"x" => 42}) == {:ok, 42}
    end

    test "atom-keyed datamodel lookup" do
      assert Expression.evaluate("data.foo", %{"data" => %{foo: 1}}) == {:ok, 1}
    end

    test "indexing a non-indexable value yields :undef" do
      assert Expression.evaluate("data.s[0]", %{"data" => %{"s" => "abc"}}) == {:ok, :undef}
    end

    test "indexing a map with a non-string key yields :undef" do
      assert Expression.evaluate("data[0]", %{"data" => %{}}) == {:ok, :undef}
    end
  end

  describe "evaluate/2 — built-in functions" do
    test "In/IsDefined/Undefined/Length/Not" do
      assert Expression.evaluate("In('a', 'a')", %{}) == {:ok, true}
      assert Expression.evaluate("In('a', 'b')", %{}) == {:ok, false}

      assert Expression.evaluate("In(data.states, 'b')", %{"data" => %{"states" => ["a", "b"]}}) ==
               {:ok, true}

      assert Expression.evaluate("IsDefined(data.x)", %{"data" => %{"x" => 1}}) == {:ok, true}
      assert Expression.evaluate("IsDefined(data.x)", %{"data" => %{}}) == {:ok, false}
      assert Expression.evaluate("Undefined(data.x)", %{"data" => %{}}) == {:ok, true}

      assert Expression.evaluate("Length(data.list)", %{"data" => %{"list" => [1, 2, 3]}}) ==
               {:ok, 3}

      assert Expression.evaluate("Not(true)", %{}) == {:ok, false}
    end

    test "unknown function returns an error" do
      assert Expression.evaluate("Foo(1)", %{}) == {:error, {:unknown_function, "Foo"}}
    end

    test "wrong arity for In falls through to unknown function" do
      assert Expression.evaluate("In()", %{}) == {:error, {:unknown_function, "In"}}
    end
  end

  describe "evaluate/2 — errors" do
    test "unexpected character" do
      assert Expression.evaluate("@@@", %{}) == {:error, {:unexpected_char, "@"}}
    end

    test "unbalanced parenthesis" do
      assert {:error, _} = Expression.evaluate("(1", %{})
    end

    test "unbalanced bracket" do
      assert Expression.evaluate("data[", %{}) == {:error, :expected_rbracket}
    end

    test "missing comma/rparen in function args" do
      assert Expression.evaluate("In(a b)", %{}) == {:error, :expected_comma_or_rparen}
    end

    test "incompatible comparison falls to unsupported operation" do
      assert {:error, {:unsupported_operation, {"<", "a", 1}}} = Expression.evaluate("'a' < 1", %{})
    end

    test "division by zero returns an error" do
      assert {:error, {:unsupported_operation, {"/", 10, 0}}} = Expression.evaluate("10 / 0", %{})
    end
  end

  describe "guard_true?/2" do
    test "nil guard and boolean results" do
      assert Expression.guard_true?(nil, %{})
      assert Expression.guard_true?("data.amount > 10", %{"data" => %{"amount" => 20}})
      refute Expression.guard_true?("data.amount > 10", %{"data" => %{"amount" => 5}})
    end

    test "truthiness of non-boolean results" do
      assert Expression.guard_true?("data.n", %{"data" => %{"n" => 5}})
      refute Expression.guard_true?("data.n", %{"data" => %{"n" => 0}})
      assert Expression.guard_true?("data.s", %{"data" => %{"s" => "hi"}})
      refute Expression.guard_true?("data.s", %{"data" => %{"s" => ""}})
      assert Expression.guard_true?("data.x", %{"data" => %{"x" => %{}}})
      refute Expression.guard_true?("data.x", %{"data" => %{"x" => nil}})
      refute Expression.guard_true?("data.m", %{"data" => %{}})
      refute Expression.guard_true?("10 / 0", %{})
    end
  end

  describe "Tokenizer.tokenize/1" do
    test "parentheses, brackets, and comma" do
      assert {:ok, tokens} = Tokenizer.tokenize("(a)")
      assert {:lparen, nil} in tokens
      assert {:rparen, nil} in tokens
      assert {:id, "a"} in tokens

      assert {:ok, tokens} = Tokenizer.tokenize("[x]")
      assert {:lbracket, nil} in tokens
      assert {:rbracket, nil} in tokens

      assert {:ok, tokens} = Tokenizer.tokenize("a, b")
      assert {:comma, nil} in tokens
    end

    test "float numbers and multi-char operators" do
      assert Tokenizer.tokenize("1.5") == {:ok, [{:num, 1.5}]}
      assert {:ok, tokens} = Tokenizer.tokenize("a <= b")
      assert {:op, "<="} in tokens
    end

    test "lenient unterminated string" do
      assert Tokenizer.tokenize("'abc") == {:ok, [{:str, "abc"}]}
    end

    test "unexpected character error" do
      assert Tokenizer.tokenize("@") == {:error, {:unexpected_char, "@"}}
    end
  end

  describe "Parser.parse/1" do
    test "binary and unary expressions" do
      assert Parser.parse([{:num, 1}, {:op, "+"}, {:num, 2}]) ==
               {:ok, {:binary, "+", {:num, 1}, {:num, 2}}}

      assert Parser.parse([{:op, "not"}, {:id, "true"}]) == {:ok, {:unary, "not", {:bool, true}}}
    end

    test "bracket index and chained index" do
      assert Parser.parse([{:id, "data"}, {:lbracket, nil}, {:num, 1}, {:rbracket, nil}]) ==
               {:ok, {:index, {:var, "data"}, {:num, 1}}}

      assert Parser.parse([
               {:id, "data"},
               {:lbracket, nil},
               {:id, "a"},
               {:rbracket, nil},
               {:lbracket, nil},
               {:id, "b"},
               {:rbracket, nil}
             ]) == {:ok, {:index, {:index, {:var, "data"}, {:var, "a"}}, {:var, "b"}}}
    end

    test "error paths" do
      assert Parser.parse([]) == {:error, :unexpected_eof}
      assert Parser.parse([{:lparen, nil}, {:num, 1}]) == {:error, {[{:num, 1}], :expected_rparen}}
      assert Parser.parse([{:id, "data"}, {:lbracket, nil}, {:num, 1}]) == {:error, :expected_rbracket}
      assert {:error, {:unexpected_token, _}} = Parser.parse([{:weird, 1}])
    end
  end

  describe "Evaluator.eval/2 (direct, internal paths)" do
    test "unsupported node, unknown unary, and non-indexable index" do
      assert Evaluator.eval({:bogus, 1}, %{}) == {:error, {:unsupported_node, {:bogus, 1}}}
      assert Evaluator.eval({:unary, "x", {:num, 1}}, %{}) == {:ok, 1}
      assert Evaluator.eval({:index, {:str, "abc"}, {:num, 0}}, %{}) == {:ok, :undef}
    end

    test "literal true/false variable resolution" do
      assert Evaluator.eval({:var, "true"}, %{}) == {:ok, true}
      assert Evaluator.eval({:var, "false"}, %{}) == {:ok, false}
    end
  end
end
