defmodule Relay.Access.UserHandler do
  @moduledoc """
  The behaviour of a consumer of Access user lifecycle events (TN-20, TN-73): the operator surface revokes the sessions of a suspended or deleted user, and suspends or reactivates the subscribers whose `external_id` is the user's pairwise `sub`. Handlers are listed in `config :relay, Relay.Access, user_handlers: [module]` and are called by the event consumer, outside any transaction, with the Access subject and the Access event's SET `jti`.
  """

  @doc "Handles a user event; an error retries the event."
  @callback handle_user_event(
              kind :: :suspended | :reactivated | :deleted,
              subject :: String.t(),
              event_ref :: String.t()
            ) :: :ok | {:error, term()}
end
