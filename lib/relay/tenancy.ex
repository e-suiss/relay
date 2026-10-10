defmodule Relay.Tenancy do
  @moduledoc """
  Tenants, sub-tenants, environments, identities and the kill switch. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []
end
