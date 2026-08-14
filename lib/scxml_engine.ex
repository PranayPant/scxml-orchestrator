defmodule ScxmlEngine do
  @moduledoc """
  Primary public API for the SCXML orchestrator runtime.

  The engine flow is:

      1. `ScxmlEngine.load/1` — ingest a parser AST JSON string.
      2. `ScxmlEngine.store/2` — compile + store the graph in `:persistent_term`.
      3. `ScxmlEngine.start_instance/2` — spawn a running instance.
      4. `ScxmlEngine.send_event/3` — drive the instance.
      5. `ScxmlEngine.active_configuration/1` / `datamodel/1` — inspect it.

  A simpler end-to-end path is `ScxmlEngine.run/2` which loads, stores, starts,
  and returns the started instance pid in one call.

  ## Example

      {:ok, pid} = ScxmlEngine.run(ast_json)
      ScxmlEngine.send_event(pid, "next")
      ScxmlEngine.active_configuration(pid)
  """

  # ---------------------------------------------------------------------------
  # Graph compilation / storage
  # ---------------------------------------------------------------------------
  alias ScxmlEngine.Compiler
  alias ScxmlEngine.Document
  alias ScxmlEngine.Instance
  alias ScxmlEngine.Instances
  alias ScxmlEngine.Registry

  @doc """
  Parse a parser-AST JSON string into a raw, un-compiled `ScxmlEngine.RuntimeGraph`.

  Returns `{:ok, graph}` or `{:error, reason}`.
  """
  @spec load(String.t()) :: {:ok, ScxmlEngine.RuntimeGraph.t()} | {:error, term()}
  def load(json) when is_binary(json) do
    Document.load(json)
  end

  @doc """
  Compile (and optionally store) a graph. When `store` is `true` (default) the
  compiled graph is placed in `:persistent_term` under `graph_id` and the id is
  returned. When `graph_id` is `nil`, the graph's `id` (or a generated id) is used.

  Returns `{:ok, graph_id}`.
  """

  # ---------------------------------------------------------------------------
  # Instance lifecycle
  # ---------------------------------------------------------------------------

  @spec store(ScxmlEngine.RuntimeGraph.t(), String.t() | nil) :: {:ok, String.t()}
  def store(%ScxmlEngine.RuntimeGraph{} = graph, graph_id \\ nil) do
    Compiler.store(graph, graph_id)
  end

  @doc """
  Load a JSON document, compile + store its graph, and start an instance for it.

  Options:
    * `:graph_id` — id to store the graph under (defaults to document id).
    * `:instance_id` — unique id to register the instance under.
    * `:initial_datamodel` — initial data.

  Returns `{:ok, pid}`.
  """
  @spec run(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def run(json, opts \\ []) when is_binary(json) do
    with {:ok, graph} <- Document.load(json) do
      graph_id = Keyword.get(opts, :graph_id)
      {:ok, graph_id} = Compiler.store(graph, graph_id)

      instance_id = Keyword.get(opts, :instance_id, graph_id)
      initial_datamodel = Keyword.get(opts, :initial_datamodel, %{})

      Instances.start_instance(
        graph_id: graph_id,
        instance_id: instance_id,
        initial_datamodel: initial_datamodel
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Instance interaction
  # ---------------------------------------------------------------------------

  @doc """
  Start an instance for an already-stored graph.

  Options: `:graph_id` (required), `:instance_id`, `:initial_datamodel`.
  Returns `{:ok, pid}`.
  """
  @spec start_instance(keyword()) :: {:ok, pid()} | :error
  def start_instance(opts) do
    Instances.start_instance(opts)
  end

  @doc """
  Send an event to an instance by pid.
  """
  @spec send_event(pid(), String.t(), term()) :: :ok
  def send_event(pid, event_name, payload \\ %{}), do: Instance.send_event(pid, event_name, payload)

  @doc """
  Send an event to an instance by its registered `instance_id`.
  """
  @spec send_event_to(String.t(), String.t(), term()) :: :ok | :error
  def send_event_to(instance_id, event_name, payload \\ %{}) do
    case Registry.lookup(instance_id) do
      {:ok, pid} -> Instance.send_event(pid, event_name, payload)
      :error -> :error
    end
  end

  @doc """
  Look up a running instance's pid by `instance_id`.
  """
  @spec instance_pid(String.t()) :: {:ok, pid()} | :error | nil
  def instance_pid(instance_id), do: Registry.lookup(instance_id)

  @doc """
  Current active configuration (`MapSet` of state ids) of an instance.
  """
  @spec active_configuration(pid()) :: MapSet.t()
  def active_configuration(pid), do: Instance.active_configuration(pid)

  @doc """
  Current datamodel of an instance.
  """
  @spec datamodel(pid()) :: map()
  def datamodel(pid), do: Instance.datamodel(pid)

  @doc """
  `true` when the instance has settled / finished (no active states).
  """
  @spec done?(pid()) :: boolean()
  def done?(pid), do: Instance.done?(pid)

  @doc """
  Execution status of an instance (`:idle | :running | :completed | :error`).
  """
  @spec execution_status(pid()) :: :idle | :running | :completed | :error
  def execution_status(pid), do: Instance.execution_status(pid)

  @doc """
  Status of each active state in the current configuration.

  Returns a list of `%{id: String.t(), status: state_status(), type: state_type()}`
  maps where `state_status()` is `:running`, `:completed`, or `:error` and
  `state_type()` is `:normal`, `:parallel`, or `:final`. Only states in the
  active configuration are included.
  """
  @spec active_states(pid()) :: [ScxmlEngine.Instance.state_info()]
  def active_states(pid), do: Instance.active_states(pid)

  @doc """
  Enumerate all running instance `{instance_id, pid}` pairs.
  """
  @spec instances() :: [{String.t(), pid()}]
  def instances, do: Registry.instances()
end
