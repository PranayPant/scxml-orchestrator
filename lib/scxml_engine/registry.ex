defmodule ScxmlEngine.Registry do
  @moduledoc """
  A process `Registry` mapping `instance_id` strings to running
  `ScxmlEngine.Instance` PIDs. This provides O(1) lookup of an instance by its
  user-facing id and a way to enumerate all running instances.

  For a BEAM cluster this could be swapped for `Horde.Registry`, but a local
  `Registry` is sufficient for the single-node case.
  """

  @registry_name __MODULE__

  @doc """
  Child spec for use in a supervisor tree.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc """
  Start the registry keyed on a tuple so we can look up by a string instance id.
  """
  def start_link(opts) do
    Registry.start_link(
      keys: :unique,
      name: @registry_name,
      keys_metadata: Keyword.get(opts, :keys_metadata, false)
    )
  end

  @doc """
  Register an instance pid under a unique `instance_id` string.
  """
  @spec register(String.t(), pid()) :: :ok
  def register(instance_id, pid) do
    Registry.register(@registry_name, instance_id, pid)
    :ok
  end

  @doc """
  Look up the pid registered under `instance_id`. Returns `{:ok, pid}` or
  `:error`.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | :error | nil
  def lookup(instance_id) do
    case Registry.lookup(@registry_name, instance_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Synchronously remove the entry for `instance_id` owned by the calling process.

  This mirrors `Registry.unregister/2`, which only removes entries registered by
  the **current process**. It must therefore be called from the process that
  registered the entry (e.g. the instance process deregistering itself on stop)
  — it is a no-op when called from a different process. Returns `:ok` even when
  there is no such entry.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(instance_id) do
    Registry.unregister(@registry_name, instance_id)
  end

  @doc """
  Return all `{instance_id, pid}` pairs currently registered.
  """
  @spec instances() :: [{String.t(), pid()}]
  def instances do
    Registry.select(@registry_name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
  end
end
