defmodule Relay.Operators.AccessSubscriberHandler do
  @moduledoc """
  The subscribers' handler of Access account lifecycle events (TN-73, E-104): `account.suspended` suspends the subscribers whose `external_id` is the pairwise `sub` the event carries and `account.reactivated` lifts their suspension (`Relay.Operators.SubscriberSuspension`); `account.deleted` leaves subscribers to their own erasure. Registered next to `Relay.Operators.AccessUserHandler` in `config :relay, Relay.Access, user_handlers: [...]`; both run for every event and an error of either retries it, so each is idempotent.
  """

  @behaviour Relay.Access.UserHandler

  alias Relay.Operators.SubscriberSuspension

  # TN-73
  # E-104
  @impl Relay.Access.UserHandler
  def handle_user_event(kind, subject, event_ref) when kind in [:suspended, :reactivated],
    do: SubscriberSuspension.access_changed(kind, subject, event_ref)

  def handle_user_event(:deleted, _subject, _event_ref), do: :ok
end
