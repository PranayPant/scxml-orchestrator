defmodule ScxmlEngine.SpanDetail do
  @moduledoc """
  Runtime gate for OpenTelemetry span fidelity.

  Host applications control how detailed the interpreter's spans are via
  `config :scxml_orchestrator, :span_detail, :info | :debug` (the
  `scxml-http-server` sets it from `SCXML_HTTP_ENGINE_LOG_LEVEL`):

    * `:info` (default) — coarse system-flow spans only
      (`macrostep.process_event`, one span per processed event).
    * `:debug` — additionally emit the fine-grained interpreter spans
      (`microstep.select_transitions`, `execute_transition`,
      `expression.evaluate`, `action.execute`).

  This library depends only on the OTel **API** (no SDK), so when no SDK is
  registered the spans are no-ops and this gate is purely a config read.
  """

  @spec debug?() :: boolean()
  def debug? do
    Application.get_env(:scxml_orchestrator, :span_detail, :info) == :debug
  end

  @doc false
  # Runs `fun`, wrapped in an OpenTelemetry span named `name` when DEBUG detail
  # is enabled; otherwise runs `fun` directly and creates no span.
  @spec with_debug_span(String.t(), (-> result)) :: result when result: term()
  def with_debug_span(name, fun) do
    if debug?() do
      O11y.with_span(name, %{}, fun)
    else
      fun.()
    end
  end
end
