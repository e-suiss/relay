defmodule Relay.Channels.Push.AccessGrant do
  @moduledoc """
  The Access implementation of `Relay.Channels.Push.CriticalGrant` (CH-66, CH-84, Access E48, E-107). The question is an AuthZEN evaluation: the subject is the sender, the Access client or agent of the event (`sender_ref`); the resource is the recipient's interruption, by the recipient's pairwise `sub` in Relay's sector (`recipient_ref`, E-90); the action is `critical` in the Access namespace `relay.interrupt` (`action/0`), the Grant a person gives on their own self-anchor; the context carries the tenant and the template key. Access names no endpoint for this decision yet, so every evaluation answers unavailable, and the channel step delivers at the class ceiling and records `critical_not_granted` (fail-closed); Relay never decides the Grant itself.
  """

  @behaviour Relay.Channels.Push.CriticalGrant

  @namespace "relay.interrupt"
  @action "critical"

  # E-107
  # CH-66
  @doc "The AuthZEN action of the critical interruption Grant: `critical` in the Access namespace `relay.interrupt`."
  @spec action() :: %{namespace: String.t(), name: String.t()}
  def action, do: %{namespace: @namespace, name: @action}

  # CH-66
  # CH-84
  # E-107
  @impl Relay.Channels.Push.CriticalGrant
  def evaluate(_query) do
    {:error,
     Relay.Error.new(
       :service_unavailable,
       "Access names no endpoint for the relay.interrupt critical decision"
     )}
  end
end
