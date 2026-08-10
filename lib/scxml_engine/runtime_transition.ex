defmodule ScxmlEngine.RuntimeTransition do
  @moduledoc """
  A compiled outgoing transition.

  The parser AST's `Transition.target` is a space-separated string that may
  hold multiple state ids (e.g. when entering a parallel region). During
  compilation this is split into `targets` (a list of state ids).

  `exit_set` and `entry_set` are pre-computed Least Common Ancestor (LCA) paths
  used at runtime to exit states (bottom-up) and enter states (top-down):

    * `exit_set` — states to exit, ordered bottom-up (deepest first).
    * `entry_set` — states to enter, ordered top-down (shallowest first).

  For an internal transition with no target, both sets are empty.
  """

  @type state_id :: String.t()

  @type t :: %__MODULE__{
          id: String.t() | nil,
          event: String.t() | nil,
          targets: [state_id],
          target_string: String.t() | nil,
          type: :external | :internal,
          cond: String.t() | nil,
          actions: [map()],
          exit_set: [state_id],
          entry_set: [state_id],
          lca_id: state_id | nil
        }

  defstruct [
    :id,
    :event,
    :targets,
    :target_string,
    :cond,
    :lca_id,
    type: :external,
    actions: [],
    exit_set: [],
    entry_set: []
  ]
end
