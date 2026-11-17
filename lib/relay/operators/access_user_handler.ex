defmodule Relay.Operators.AccessUserHandler do
  @moduledoc """
  The operator surface's handler of Access account lifecycle events (TN-20, E-104): the person an `account.suspended` or `account.deleted` event names by its pairwise `sub` loses every Relay session at once, and after `account.reactivated` may sign in again; roles stay in Relay. Registered as `config :relay, Relay.Access, user_handlers: [Relay.Operators.AccessUserHandler]`.
  """

  @behaviour Relay.Access.UserHandler

  @statuses %{suspended: :suspended, reactivated: :active, deleted: :deleted}

  # TN-20
  # E-104
  @impl Relay.Access.UserHandler
  def handle_user_event(kind, subject, event_ref) when is_map_key(@statuses, kind) do
    {:ok, _result} =
      Relay.Operators.access_user_changed(subject, Map.fetch!(@statuses, kind), event_ref)

    :ok
  end
end
