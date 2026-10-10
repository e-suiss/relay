defmodule Relay.Inbox do
  @moduledoc """
  The inbox, badges and the realtime feed. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []
end
