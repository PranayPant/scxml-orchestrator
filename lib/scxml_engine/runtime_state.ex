defmodule ScxmlEngine.RuntimeState do
  @moduledoc """
  A single compiled state node in the `ScxmlEngine.RuntimeGraph`.

  The `type` is one of `:atomic | :compound | :parallel | :history | :final`,
  derived at compile time from the parser AST node kind and, for `<state>`
  elements, its `type` annotation.

  `on_entry`/`on_exit` hold lists of executable action maps (the parser's
  `ExecutableContent` JSON objects, kept verbatim). `transitions` holds the
  compiled outgoing transitions for this state.
  """

  @type state_id :: String.t()
  @type state_type :: :atomic | :compound | :parallel | :history | :final

  @type t :: %__MODULE__{
          id: state_id,
          type: state_type,
          initial: state_id | nil,
          on_entry: [map()],
          on_exit: [map()],
          transitions: [ScxmlEngine.RuntimeTransition.t()],
          history_type: :shallow | :deep | nil,
          # default target(s) for a history pseudo-state, if any
          history_targets: [state_id] | nil
        }

  defstruct [
    :id,
    :type,
    :initial,
    :history_type,
    :history_targets,
    on_entry: [],
    on_exit: [],
    transitions: []
  ]
end
