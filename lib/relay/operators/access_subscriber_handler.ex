defmodule Relay.Operators.AccessSubscriberHandler do
  @moduledoc """
  The subscribers' handler of Access user lifecycle events (TN-73): `user.suspended` suspends the subscribers whose `external_id` is the user's pairwise `sub` and `user.reactivated` lifts their suspension (`Relay.Operators.SubscriberSuspension`); `user.deleted` leaves subscribers to their own erasure. Registered next to `Relay.Operators.AccessUserHandler` in `config :relay, Relay.Access, user_handlers: [...]`; both run for every event and an error of either retries it, so each is idempotent.
  """

  @behaviour Relay.Access.UserHandler

  alias Relay.Operators.SubscriberSuspension

  # TN-73
  @impl Relay.Access.UserHandler
  def handle_user_event(kind, subject, event_ref) when kind in [:suspended, :reactivated],
    do: SubscriberSuspension.access_changed(kind, subject, event_ref)

  def handle_user_event(:deleted, _subject, _event_ref), do: :ok
end
