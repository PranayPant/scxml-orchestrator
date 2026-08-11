defmodule ScxmlEngine.Expression.Tokenizer do
  @moduledoc """
  Tokenizes an SCXML expression string into a list of tokens for the
  sandboxed `ScxmlEngine.Expression` evaluator.

  Recognized tokens: numbers, identifiers (including dotted paths), string
  literals, operators/punctuation, and known keywords (`and`, `or`, `not`,
  `true`, `false`).
  """

  @type token ::
          {:num, number()}
          | {:str, String.t()}
          | {:id, String.t()}
          | {:op, String.t()}
          | {:lparen, nil}
          | {:rparen, nil}
          | {:lbracket, nil}
          | {:rbracket, nil}
          | {:comma, nil}

  @operators [
    "<=",
    ">=",
    "==",
    "!=",
    "&&",
    "||",
    ">",
    "<",
    "+",
    "-",
    "*",
    "/",
    "%",
    "=",
    "!"
  ]

  @spec tokenize(String.t()) :: {:ok, [token()]} | {:error, term()}
  def tokenize(expr) when is_binary(expr) do
    expr
    |> String.trim()
    |> do_tokenize([], [])
    |> case do
      {:ok, tokens} -> {:ok, Enum.reverse(tokens)}
      other -> other
    end
  end

  # Consume characters one at a time; `tokens` is accumulated reversed.
  defp do_tokenize("", tokens, _acc), do: {:ok, tokens}

  defp do_tokenize(<<c::utf8, rest::binary>>, tokens, acc) do
    cond do
      c in [?\s, ?\t, ?\n, ?\r] ->
        do_tokenize(rest, tokens, acc)

      c in ?0..?9 ->
        {num, rest2} = take_number(<<c::utf8, rest::binary>>, [])
        do_tokenize(rest2, [{:num, parse_number(num)} | tokens], acc)

      c == ?' or c == ?" ->
        {str, rest2} = take_string(<<c::utf8, rest::binary>>, c, [])
        do_tokenize(rest2, [{:str, str} | tokens], acc)

      c == ?( ->
        do_tokenize(rest, [{:lparen, nil} | tokens], acc)

      c == ?) ->
        do_tokenize(rest, [{:rparen, nil} | tokens], acc)

      c == ?[ ->
        do_tokenize(rest, [{:lbracket, nil} | tokens], acc)

      c == ?] ->
        do_tokenize(rest, [{:rbracket, nil} | tokens], acc)

      c == ?, ->
        do_tokenize(rest, [{:comma, nil} | tokens], acc)

      identifier_start?(c) ->
        {ident, rest2} = take_identifier(<<c::utf8, rest::binary>>, [])
        token = classify_identifier(ident)
        do_tokenize(rest2, [token | tokens], acc)

      true ->
        case take_operator(<<c::utf8, rest::binary>>) do
          {nil, _} -> {:error, {:unexpected_char, <<c::utf8>>}}
          {op, rest2} -> do_tokenize(rest2, [{:op, op} | tokens], acc)
        end
    end
  end

  defp identifier_start?(c) do
    (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or c == ?_ or c == ?$
  end

  defguardp is_ident_char(c)
            when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or
                   (c >= ?0 and c <= ?9) or c == ?_ or c == ?$ or c == ?.

  defp take_identifier(bin, acc) do
    case bin do
      <<c::utf8, rest::binary>> when is_ident_char(c) ->
        take_identifier(rest, [c | acc])

      _ ->
        {acc |> Enum.reverse() |> List.to_string(), bin}
    end
  end

  defp take_number(bin, acc) do
    case bin do
      <<c::utf8, rest::binary>> when c in ?0..?9 or c == ?. ->
        take_number(rest, [c | acc])

      _ ->
        {acc |> Enum.reverse() |> List.to_string(), bin}
    end
  end

  defp take_string(<<_quote::utf8, rest::binary>>, quote_char, acc) do
    take_string_loop(rest, quote_char, acc)
  end

  defp take_string_loop(bin, quote, acc) do
    case bin do
      <<c::utf8, rest::binary>> when c == quote ->
        {acc |> Enum.reverse() |> List.to_string(), rest}

      <<c::utf8, rest::binary>> ->
        take_string_loop(rest, quote, [c | acc])

      "" ->
        {acc |> Enum.reverse() |> List.to_string(), ""}
    end
  end

  defp take_operator(bin) do
    matched = Enum.find(@operators, &String.starts_with?(bin, &1))

    case matched do
      nil ->
        {nil, bin}

      op ->
        {op, String.replace_prefix(bin, op, "")}
    end
  end

  defp classify_identifier(ident) do
    case ident do
      "true" -> {:id, "true"}
      "false" -> {:id, "false"}
      "and" -> {:op, "and"}
      "or" -> {:op, "or"}
      "not" -> {:op, "not"}
      _ -> {:id, ident}
    end
  end

  defp parse_number(str) do
    if String.contains?(str, ".") do
      String.to_float(str)
    else
      String.to_integer(str)
    end
  end
end
