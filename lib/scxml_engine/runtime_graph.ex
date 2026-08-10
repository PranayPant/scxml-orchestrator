defmodule ScxmlEngine.RuntimeGraph do
  @moduledoc """
  The compiled, immutable runtime representation of a statechart.

  This is produced by `ScxmlEngine.Compiler.compile/1` from a parser AST JSON
  document and stored in `:persistent_term` so that millions of running
  instance processes can read it concurrently without copying the structure
  into their own heaps (zero-copy access).

  All lookup-oriented data is pre-computed at compile time so that transitions
  during runtime microsteps require only simple map lookups.
  """

  @type state_id :: String.t()

  @type t :: %__MODULE__{
          id: String.t() | nil,
          initial: state_id | nil,
          states: %{optional(state_id) => ScxmlEngine.RuntimeState.t()},
          parent_map: %{optional(state_id) => state_id},
          ancestors_map: %{optional(state_id) => [state_id]},
          event_index: %{
            exact: %{optional(String.t()) => [ScxmlEngine.RuntimeTransition.t()]},
            patterns: [ScxmlEngine.RuntimeTransition.t()]
          }
        }

  defstruct [
    :id,
    :initial,
    :states,
    :parent_map,
    :ancestors_map,
    :event_index
  ]
end
