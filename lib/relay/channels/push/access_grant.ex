defmodule Relay.Channels.Push.AccessGrant do
  @moduledoc """
  The Access implementation of `Relay.Channels.Push.CriticalGrant` (CH-66, CH-84, Access E48). The question is an AuthZEN evaluation (`POST /access/v1/evaluation`): the subject is the sender, the Access client or agent of the event (`sender_ref`); the resource is the recipient, by its pairwise `sub` in Relay's sector (`recipient_ref`, E-90); the action is `interrupt.critical`; the context carries the tenant and the template key. Access does not yet define this decision, so every evaluation answers unavailable, and the channel step delivers at the class ceiling and records `critical_not_granted` (fail-closed); Relay never decides the Grant itself.
  """

  @behaviour Relay.Channels.Push.CriticalGrant

  # CH-66
  # CH-84
  @impl Relay.Channels.Push.CriticalGrant
  def evaluate(_query) do
    {:error,
     Relay.Error.new(
       :service_unavailable,
       "Access defines no decision for the critical interruption Grant"
     )}
  end
end
