defmodule ScxmlOrchestrator do
  @moduledoc """
  Top-level facade for the SCXML orchestrator runtime.

  This delegates to `ScxmlEngine`, which exposes the full pipeline: ingest a
  parser AST JSON document, compile it into an optimized runtime graph, store
  it for zero-copy access, and run the statechart through `ScxmlEngine.Instance`
  processes.

  See `ScxmlEngine` for the primary API.
  """

  defdelegate load(json), to: ScxmlEngine
  defdelegate store(graph, graph_id \\ nil), to: ScxmlEngine
  defdelegate run(json, opts \\ []), to: ScxmlEngine
  defdelegate start_instance(opts), to: ScxmlEngine
  defdelegate instance_pid(instance_id), to: ScxmlEngine
  defdelegate active_configuration(pid), to: ScxmlEngine
  defdelegate datamodel(pid), to: ScxmlEngine
  defdelegate done?(pid), to: ScxmlEngine
  defdelegate instances(), to: ScxmlEngine
end
