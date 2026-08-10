defmodule ScxmlEngine.Expression do
  @moduledoc """
  A **restricted, sandboxed** expression evaluator for SCXML `cond` guards and
  simple `expr` attributes.

  Only a fixed, closed set of operations is supported — the evaluator never
  delegates to `Code.eval_string/2`, so untrusted SCXML input cannot trigger
  arbitrary code execution (RCE). Supported features:

    * Integers and floats.
    * String literals (single or double quotes).
    * Booleans: `true` / `false`, and comparison results.
    * Arithmetic: `+ - * / %` (with unary `-`).
    * Comparisons: `== != < <= > >=` (numeric and string equality supported).
    * Boolean logic: `and` / `or` / `not` (and `&&` / `||` / `!`).
    * Variables and dotted path access into the datamodel
      (e.g. `data.amount`, `data.user.name`).
    * Bracketed key access: `data["key"]`, `data['key']`.
    * The special `_event` value in the datamodel.
    * Safe built-in functions: `In(state_id_or_list, value)`, `IsDefined(x)`,
      `Undefined(x)`.

  `true`, `false`, and `undef` result values are represented as the atoms
  `true`, `false`, and `:undef` (SCXML's undefined value). Guard evaluation
  treats a result of `true` as passing and everything else as failing.

  This is intentionally a **minimal** SCXML expression subset designed to cover
  the guard patterns seen in practice (`data.amount > 100`, `In("s1")`, etc.).
  It is not a full ECMAScript evaluator. If a richer expression language is
  required later, extend the safe function table here rather than reaching for
  `Code.eval_string/2`.
  """

  alias ScxmlEngine.Expression.Evaluator
  alias ScxmlEngine.Expression.Parser
  alias ScxmlEngine.Expression.Tokenizer

  @doc """
  Evaluate an expression string against a `datamodel` map.

  Returns `{:ok, value}` on success or `{:error, reason}` on a syntax/runtime
  error. `value` is `true`/`false`, a number, a string, `nil`, or the `:undef`
  atom.
  """
  @spec evaluate(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def evaluate(expr, datamodel) when is_binary(expr) do
    with {:ok, tokens} <- Tokenizer.tokenize(expr),
         {:ok, ast} <- Parser.parse(tokens) do
      Evaluator.eval(ast, datamodel)
    end
  end

  @doc """
  Convenience guard checker: returns `true` only if `expr` evaluates to
  boolean `true`. Returns `true` when `expr` is `nil` (no guard).
  """
  @spec guard_true?(String.t() | nil, map()) :: boolean()
  def guard_true?(nil, _datamodel), do: true

  def guard_true?(expr, datamodel) do
    case evaluate(expr, datamodel) do
      {:ok, true} -> true
      {:ok, false} -> false
      {:ok, other} -> truthy?(other)
      {:error, _} -> false
    end
  end

  defp truthy?(nil), do: false
  defp truthy?(:undef), do: false
  defp truthy?(val) when is_number(val), do: val != 0
  defp truthy?(val) when is_binary(val), do: val != ""
  defp truthy?(_), do: true
end
