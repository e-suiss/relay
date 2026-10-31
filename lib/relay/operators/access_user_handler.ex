defmodule Relay.Operators.AccessUserHandler do
  @moduledoc """
  The operator surface's handler of Access user lifecycle events (TN-20): a suspended or deleted Access user loses every Relay session at once and a reactivated one may sign in again; roles stay in Relay. Registered as `config :relay, Relay.Access, user_handlers: [Relay.Operators.AccessUserHandler]`.
  """

  @behaviour Relay.Access.UserHandler

  @statuses %{suspended: :suspended, reactivated: :active, deleted: :deleted}

  # TN-20
  @impl Relay.Access.UserHandler
  def handle_user_event(kind, subject, event_ref) when is_map_key(@statuses, kind) do
    {:ok, _result} =
      Relay.Operators.access_user_changed(subject, Map.fetch!(@statuses, kind), event_ref)

    :ok
  end
end
