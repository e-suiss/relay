defmodule Relay.Channels do
  @moduledoc """
  Channel adapters, providers and failover. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []
end
