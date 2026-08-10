defmodule ScxmlEngine.Expression.Parser do
  @moduledoc """
  Parses the token stream from `ScxmlEngine.Expression.Tokenizer` into a small
  AST for the sandboxed `ScxmlEngine.Expression` evaluator.

  The AST is a plain term tree:

    * `{:num, value}`, `{:str, value}`, `{:bool, value}` — literals
    * `{:var, "data.amount"}` — variable / dotted path
    * `{:unary, op, operand}`
    * `{:binary, op, left, right}`
    * `{:call, "In", [args]}`, `{:call, "IsDefined", [x]}`
    * `{:index, target, key_expr}` — bracket access
  """

  alias ScxmlEngine.Expression.Tokenizer

  @infix_operators %{
    "or" => 10,
    "||" => 10,
    "and" => 20,
    "&&" => 20,
    "==" => 30,
    "!=" => 30,
    "<" => 40,
    "<=" => 40,
    ">" => 40,
    ">=" => 40,
    "+" => 50,
    "-" => 50,
    "*" => 60,
    "/" => 60,
    "%" => 60
  }

  @right_assoc MapSet.new([])

  @spec parse([Tokenizer.token()]) :: {:ok, term()} | {:error, term()}
  def parse(tokens) do
    with {:ok, ast, []} <- parse_expr(tokens, 0) do
      {:ok, ast}
    end
  end

  defp parse_expr(tokens, min_prec) do
    with {:ok, lhs, tokens} <- parse_prefix(tokens) do
      parse_infix(lhs, tokens, min_prec)
    end
  end

  defp parse_infix(lhs, tokens, min_prec) do
    case tokens do
      [{:op, op} | rest] when is_binary(op) and is_map_key(@infix_operators, op) ->
        prec = Map.fetch!(@infix_operators, op)

        if prec < min_prec do
          {:ok, lhs, tokens}
        else
          new_min = if MapSet.member?(@right_assoc, op), do: prec, else: prec + 1

          with {:ok, rhs, tokens2} <- parse_expr(rest, new_min) do
            parse_infix({:binary, op, lhs, rhs}, tokens2, min_prec)
          end
        end

      _ ->
        {:ok, lhs, tokens}
    end
  end

  defp parse_prefix([{:num, n} | rest]), do: {:ok, {:num, n}, rest}
  defp parse_prefix([{:str, s} | rest]), do: {:ok, {:str, s}, rest}

  defp parse_prefix([{:id, "true"} | rest]), do: {:ok, {:bool, true}, rest}
  defp parse_prefix([{:id, "false"} | rest]), do: {:ok, {:bool, false}, rest}

  defp parse_prefix([{:id, name} | rest]) do
    # Function call or variable?
    case rest do
      [{:lparen, nil} | rest2] ->
        with {:ok, args, rest3} <- parse_args(rest2, []) do
          {:ok, {:call, name, args}, rest3}
        end

      _ ->
        parse_postfix({:var, name}, rest)
    end
  end

  defp parse_prefix([{:op, "not"} | rest]) do
    with {:ok, operand, rest2} <- parse_prefix(rest) do
      {:ok, {:unary, "not", operand}, rest2}
    end
  end

  defp parse_prefix([{:op, "!"} | rest]) do
    with {:ok, operand, rest2} <- parse_prefix(rest) do
      {:ok, {:unary, "not", operand}, rest2}
    end
  end

  defp parse_prefix([{:op, "-"} | rest]) do
    with {:ok, operand, rest2} <- parse_prefix(rest) do
      {:ok, {:unary, "-", operand}, rest2}
    end
  end

  defp parse_prefix([{:lparen, nil} | rest]) do
    with {:ok, inner, rest2} <- parse_expr(rest, 0),
         [{:rparen, nil} | rest3] <- rest2 do
      {:ok, inner, rest3}
    else
      _ -> {:error, {rest, :expected_rparen}}
    end
  end

  defp parse_prefix([]), do: {:error, :unexpected_eof}
  defp parse_prefix(other), do: {:error, {:unexpected_token, other}}

  # Parse bracket/postfix access such as `data["key"]`.
  defp parse_postfix(node, [{:lbracket, nil} | rest]) do
    case parse_expr(rest, 0) do
      {:ok, key_expr, [{:rbracket, nil} | rest2]} ->
        # allow chained index, though uncommon
        parse_postfix({:index, node, key_expr}, rest2)

      _ ->
        {:error, :expected_rbracket}
    end
  end

  defp parse_postfix(node, rest), do: {:ok, node, rest}

  defp parse_args([{:rparen, nil} | rest], acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_args(tokens, acc) do
    with {:ok, arg, rest} <- parse_expr(tokens, 0) do
      case rest do
        [{:comma, nil} | rest2] -> parse_args(rest2, [arg | acc])
        [{:rparen, nil} | rest2] -> {:ok, Enum.reverse([arg | acc]), rest2}
        _ -> {:error, :expected_comma_or_rparen}
      end
    end
  end
end
