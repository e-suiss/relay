defmodule Relay.Delivery do
  @moduledoc """
  The delivery ledger, delivery state and reconciliation. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []
end
