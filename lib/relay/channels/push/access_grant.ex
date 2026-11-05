defmodule Relay.Channels.Push.AccessGrant do
  @moduledoc """
  The Access implementation of `Relay.Channels.Push.CriticalGrant` (CH-66, Access E48). Access offers the AuthZEN evaluation endpoint (`POST /access/v1/evaluation`), but it does not yet define the Grant of critical interruption: no action, resource type or context for it is specified, so there is no question Relay could ask. Until Access defines it, every evaluation answers unavailable, and the channel step delivers at the class ceiling and records `critical_not_granted` (fail-closed); Relay never decides the Grant itself.

  What Access must define for this module to ask: the action (proposed `relay.push.interrupt_critical`), the resource type of the sender the Grant names (proposed `relay_sender`, identified by the sender reference: the Access client or agent instance of the event), the subject (the recipient's Access Party), the context members (the tenant, the template key or the `critical` sender declaration, and the Grant scope it is matched against, such as "everything from this sender") and the answer, a permit or deny with a decision reference Relay records with the delivery.
  """

  @behaviour Relay.Channels.Push.CriticalGrant

  # CH-66
  @impl Relay.Channels.Push.CriticalGrant
  def evaluate(_query) do
    {:error,
     Relay.Error.new(
       :service_unavailable,
       "Access defines no decision for the critical interruption Grant"
     )}
  end
end
