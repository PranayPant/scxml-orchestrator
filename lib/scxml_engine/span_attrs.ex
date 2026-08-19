defmodule ScxmlEngine.SpanAttrs do
  @moduledoc """
  Human-readable formatting helpers for OpenTelemetry span attributes emitted by
  the interpreter (`ScxmlEngine.Instance`).

  The `open_telemetry_decorator`/`o11y` stack stringifies non-primitive attribute
  values with `Kernel.inspect/1`, which produces noisy output for state
  configurations and transition structs. These helpers render them as compact,
  legible strings instead (e.g. `"idle,running"` and `"processing ->done-> finished"`).
  """

  @doc """
  Render a list of state ids (a configuration, exit set, or entry set) as a
  compact comma-joined string, e.g. `"idle,running"`. Non-list values fall back
  to `inspect/1`.
  """
  @spec config_to_string(list() | term()) :: String.t()
  def config_to_string(list) when is_list(list), do: Enum.join(list, ",")
  def config_to_string(other), do: inspect(other)

  @doc """
  Render a transition's target state id list as a compact comma-joined string,
  e.g. `"running,finished"`. Non-list values fall back to `inspect/1`.
  """
  @spec target_to_string(list() | term()) :: String.t()
  def target_to_string(targets) when is_list(targets), do: Enum.join(targets, ",")
  def target_to_string(other), do: inspect(other)

  @doc """
  Render an enabled transition as a readable `"from ->event-> targets"` string,
  e.g. `"processing ->done-> finished"`. Takes a `{from_state_id, transition}`
  tuple as produced by the interpreter's transition selection.
  """
  @spec enabled_transition_to_string({String.t(), ScxmlEngine.RuntimeTransition.t()}) :: String.t()
  def enabled_transition_to_string({from, %{event: event, targets: targets}}) do
    "#{from} ->#{event}-> #{target_to_string(targets)}"
  end
end
