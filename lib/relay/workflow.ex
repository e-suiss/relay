defmodule Relay.Workflow do
  @moduledoc """
  Workflows, steps, routing, escalation and scheduling. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []
end
