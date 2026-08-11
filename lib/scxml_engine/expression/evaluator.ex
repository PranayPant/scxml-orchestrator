defmodule ScxmlEngine.Expression.Evaluator do
  @moduledoc """
  Evaluates the AST produced by `ScxmlEngine.Expression.Parser` against a
  datamodel map. All operations are closed and sandboxed — no arbitrary code
  is ever executed.

  Variable identifiers are resolved as:

    * `data.a.b` / `data["a"].b` — nested lookups; a missing segment yields
      `:undef` (SCXML's undefined value).
    * Any other top-level name is looked up directly in the datamodel map
      (e.g. `x` resolves to `datamodel["x"]`), falling back to `:undef`.
    * `_event` resolves to `datamodel["_event"]`.
  """

  @builtin_bound_value :undef

  @spec eval(term(), map()) :: {:ok, term()} | {:error, term()}
  def eval(ast, datamodel) do
    {:ok, eval_node(ast, datamodel, %{})}
  catch
    :throw, {:scxml_eval, reason} -> {:error, reason}
  end

  # -- nodes ----------------------------------------------------------------

  defp eval_node({:num, n}, _dm, _env), do: n
  defp eval_node({:str, s}, _dm, _env), do: s
  defp eval_node({:bool, b}, _dm, _env), do: b

  defp eval_node({:var, name}, dm, _env), do: resolve_var(name, dm)

  defp eval_node({:index, target, key}, dm, env) do
    target_val = eval_node(target, dm, env)
    key_val = eval_node(key, dm, env)
    index_into(target_val, key_val)
  end

  defp eval_node({:unary, op, operand}, dm, env) do
    val = eval_node(operand, dm, env)
    apply_unary(op, val)
  end

  defp eval_node({:binary, op, left, right}, dm, env) do
    l = eval_node(left, dm, env)
    r = eval_node(right, dm, env)
    apply_binary(op, l, r)
  end

  defp eval_node({:call, name, args}, dm, env) do
    arg_vals = Enum.map(args, &eval_node(&1, dm, env))
    apply_call(name, arg_vals, dm)
  end

  defp eval_node(other, _dm, _env), do: throw({:scxml_eval, {:unsupported_node, other}})

  # -- variables ------------------------------------------------------------

  defp resolve_var("true", _dm), do: true
  defp resolve_var("false", _dm), do: false

  defp resolve_var(name, dm) do
    case String.split(name, ".", parts: 2) do
      [head, tail] when head == "data" ->
        look_up(Map.get(dm, "data", %{}), tail)

      [head, tail] ->
        base = Map.get(dm, head, @builtin_bound_value)
        look_up(base, tail)

      [_] ->
        Map.get(dm, name, @builtin_bound_value)
    end
  end

  defp look_up(container, path) do
    [key | rest] = String.split(path, ".")

    val = index_into(container, key)

    case {val, rest} do
      {@builtin_bound_value, _} ->
        @builtin_bound_value

      {val, []} ->
        val

      {val, _rest} ->
        if(is_map(val), do: look_up(val, Enum.join(rest, ".")), else: @builtin_bound_value)
    end
  end

  defp index_into(container, key) when is_map(container) do
    cond do
      is_binary(key) and Map.has_key?(container, key) -> Map.get(container, key)
      # JSON maps use string keys, but a hand-built datamodel may use atoms.
      is_binary(key) -> Map.get(container, String.to_atom(key), @builtin_bound_value)
      true -> @builtin_bound_value
    end
  end

  defp index_into(list, idx) when is_list(list) and is_integer(idx), do: Enum.at(list, idx, @builtin_bound_value)

  defp index_into(_other, _key), do: @builtin_bound_value

  # -- operators ------------------------------------------------------------

  defp apply_unary("-", val) when is_number(val), do: -val
  defp apply_unary("not", val), do: not truthy?(val)
  defp apply_unary(_, val), do: val

  defp apply_binary("+", l, r) when is_number(l) and is_number(r), do: l + r
  defp apply_binary("-", l, r) when is_number(l) and is_number(r), do: l - r
  defp apply_binary("*", l, r) when is_number(l) and is_number(r), do: l * r
  defp apply_binary("/", l, r) when is_number(l) and is_number(r) and r != 0, do: l / r

  defp apply_binary("%", l, r) when is_number(l) and is_number(r) and r != 0, do: rem(trunc(l), trunc(r))

  defp apply_binary("+", l, r) when is_binary(l) and is_binary(r), do: l <> r

  defp apply_binary("==", l, r), do: l == r
  defp apply_binary("!=", l, r), do: l != r
  defp apply_binary("<", l, r) when is_number(l) and is_number(r), do: l < r
  defp apply_binary("<=", l, r) when is_number(l) and is_number(r), do: l <= r
  defp apply_binary(">", l, r) when is_number(l) and is_number(r), do: l > r
  defp apply_binary(">=", l, r) when is_number(l) and is_number(r), do: l >= r

  defp apply_binary("and", l, r), do: truthy?(l) and truthy?(r)
  defp apply_binary("or", l, r), do: truthy?(l) or truthy?(r)
  defp apply_binary("&&", l, r), do: truthy?(l) and truthy?(r)
  defp apply_binary("||", l, r), do: truthy?(l) or truthy?(r)

  defp apply_binary(op, l, r) do
    throw({:scxml_eval, {:unsupported_operation, {op, l, r}}})
  end

  # -- built-in functions ---------------------------------------------------

  defp apply_call("In", [target, value], _dm) do
    ids = if is_list(target), do: target, else: [target]
    elem = value
    Enum.any?(ids, &(&1 == elem)) or (is_list(elem) and Enum.any?(elem, fn e -> e in ids end))
  end

  defp apply_call("IsDefined", [val], _dm), do: val != @builtin_bound_value and not is_nil(val)
  defp apply_call("Undefined", [val], _dm), do: val == @builtin_bound_value or is_nil(val)
  defp apply_call("Length", [val], _dm) when is_list(val), do: length(val)
  defp apply_call("Not", [val], _dm), do: not truthy?(val)
  defp apply_call(name, _args, _dm), do: throw({:scxml_eval, {:unknown_function, name}})

  defp truthy?(true), do: true
  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(@builtin_bound_value), do: false
  defp truthy?(val) when is_number(val), do: val != 0
  defp truthy?(val) when is_binary(val), do: val != ""
  defp truthy?(_), do: true
end
