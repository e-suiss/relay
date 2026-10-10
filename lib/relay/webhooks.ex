defmodule Relay.Webhooks do
  @moduledoc """
  The outbound delivery engine, endpoints and the webhook portal. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []
end
