defmodule ScxmlEngine.EventMatcher do
  @moduledoc """
  Matches an incoming event name against an SCXML transition event pattern.

  SCXML supports dot-delimited event hierarchy. A pattern may be:

    * `nil` / empty  — not handled here; eventless transitions are evaluated
      separately by the interpreter.
    * a literal event name (e.g. `"user.login"`) — exact match.
    * `"*"` — matches any event.
    * a dot-prefix pattern (e.g. `"user.*"`) — matches `user`, `user.login`, etc.
    * a space-separated token list (e.g. `"done.state.a done.state.b"`) —
      matches if **any** token matches.

  This mirrors the `EventMatcher` in `ARCHITECTURE.md` §2.
  """

  # We define our own `match?/2`; exclude Kernel's pattern-matching macro so
  # there is no name conflict.
  import Kernel, except: [match?: 2]

  @doc """
  Returns `true` if `pattern` matches the `event_name`.

  ## Examples

      iex> ScxmlEngine.EventMatcher.match?("*", "anything")
      true

      iex> ScxmlEngine.EventMatcher.match?("user.login", "user.login")
      true

      iex> ScxmlEngine.EventMatcher.match?("user.*", "user.login")
      true

      iex> ScxmlEngine.EventMatcher.match?("user.*", "user")
      true

      iex> ScxmlEngine.EventMatcher.match?("user.*", "admin.login")
      false

      iex> ScxmlEngine.EventMatcher.match?("a b", "b")
      true
  """
  @spec match?(String.t() | nil, String.t()) :: boolean()
  def match?(pattern, event_name) when pattern == "*" or (not is_nil(pattern) and pattern == event_name), do: true

  def match?(nil, _event_name), do: false

  def match?(pattern, event_name) do
    cond do
      String.contains?(pattern, " ") ->
        pattern
        |> String.split(" ", trim: true)
        |> Enum.any?(&match?(&1, event_name))

      String.ends_with?(pattern, ".*") ->
        prefix = String.slice(pattern, 0..(String.length(pattern) - 3))
        event_name == prefix or String.starts_with?(event_name, prefix <> ".")

      true ->
        false
    end
  end
end
