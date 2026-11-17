defmodule Relay.Iys.Gate do
  @moduledoc """
  The İYS gate of the lattice on an installation with the İYS integration (PC-27, PC-33, PC-21, PC-24, INV-19), configured as `config :relay, Relay.Policy.IysGate, impl: Relay.Iys.Gate`. It answers from Relay's own copy of İYS, the permission cache, with one statement inside the lattice's scoped read transaction; İYS itself is never asked on the send path (PC-32), and nothing Access sends later changes the answer (§7.11).

  A tenant whose region is not Turkey and that entered no İYS configuration is `:out_of_scope`. A tenant in scope without a configuration, or without a brand for the delivery's sub-tenant, is `:not_configured`. Otherwise the answer is what the cache holds for the brand, the İYS type of the channel and the address, with the instant of the brand's last successful synchronisation, from which the lattice decides staleness.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Iys, Relay.Policy.IysGate], exports: []

  @behaviour Relay.Policy.IysGate

  # PC-27
  # PC-33
  # INV-19
  # INV-43
  @impl Relay.Policy.IysGate
  def status(%Relay.Scope{} = scope, brand, channel, address_digest) when is_atom(channel),
    do: Relay.Iys.permission(scope, brand, Atom.to_string(channel), address_digest)
end
