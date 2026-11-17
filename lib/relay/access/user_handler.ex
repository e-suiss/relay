defmodule Relay.Access.UserHandler do
  @moduledoc """
  The behaviour of a consumer of Access account lifecycle events (TN-20, TN-73, E-104): the operator surface revokes the sessions of a suspended or deleted person, and suspends or reactivates the subscribers whose `external_id` is the person's pairwise `sub`. Handlers are listed in `config :relay, Relay.Access, user_handlers: [module]` and are called by the event consumer, outside any transaction, with the pairwise `sub` an `account.suspended`, `account.reactivated` or `account.deleted` event carries and the Access event's SET `jti`; an account event that names the person only by its Access account id reaches no handler.
  """

  @doc "Handles a user event; an error retries the event."
  @callback handle_user_event(
              kind :: :suspended | :reactivated | :deleted,
              subject :: String.t(),
              event_ref :: String.t()
            ) :: :ok | {:error, term()}
end
