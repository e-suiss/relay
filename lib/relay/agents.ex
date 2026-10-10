defmodule Relay.Agents do
  @moduledoc """
  Waitpoints, agent mailboxes and agent protocols. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []
end
