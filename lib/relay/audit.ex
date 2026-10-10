defmodule Relay.Audit do
  @moduledoc """
  The audit log and its checkpoints. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []
end
