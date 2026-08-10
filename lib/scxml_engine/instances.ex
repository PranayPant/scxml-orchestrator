defmodule ScxmlEngine.Instances do
  @moduledoc """
  A `DynamicSupervisor` that spawns `ScxmlEngine.Instance` processes on demand.
  Instance crashes are isolated here so they never affect other instances or
  the registry.
  """
  use DynamicSupervisor

  @doc """
  Start the dynamic supervisor.
  """
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a new statechart instance under this supervisor.

  Accepts `ScxmlEngine.Instance.start_link/1` options plus `:instance_id` used
  to register the process in `ScxmlEngine.Registry`.
  """
  @spec start_instance(keyword()) :: DynamicSupervisor.on_start_child()
  def start_instance(opts) do
    instance_id = Keyword.fetch!(opts, :instance_id)

    spec = %{
      id: {ScxmlEngine.Instance, instance_id},
      start: {ScxmlEngine.Instance, :start_link, [opts]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
