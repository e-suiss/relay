defmodule Relay.Access.DecisionHandler do
  @moduledoc """
  The behaviour of the consumer of the Access `approval.decided` event (E-15, AG-27): a decision given on the Access approval surface closes the waitpoint whose invitation led there, at evidence level `access_aas_ref`. The handler is named in `config :relay, Relay.Access, decision_handler: module` and is called by the event consumer, outside any transaction, once for each environment of the mapped tenant.

  The decision carries `:waitpoint_id` (the waitpoint's external identifier), `:subject` (the pairwise `sub` of the person who decided), `:value` (the decision as a response value), `:decision_ref` (the reference of the decision on the approval surface), `:subject_digest` (raw bytes) and `:source_event_ref` (the event's SET `jti`).
  """

  @doc "Handles a decision in one tenant environment: `:ok` when it is recorded there (again, on a repeated event), `:unknown` when the environment has no such waitpoint or person, `{:rejected, reason}` when the waitpoint refused it, and an error retries the event."
  @callback handle_decision(scope :: Relay.Scope.t(), decision :: map()) ::
              :ok | :unknown | {:rejected, String.t()} | {:error, term()}
end
