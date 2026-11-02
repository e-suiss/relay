defmodule Relay.Access.ConsentHandler do
  @moduledoc """
  The behaviour of the consumer of the Access `consent.updated` event (E-80, PC-59 (1)): the consent copy records the consent of the subscriber whose `external_id` is the event's pairwise `sub` in one tenant environment. The handler is named in `config :relay, Relay.Access, consent_handler: module` and is called by the event consumer, outside any transaction, once for each environment of the mapped tenant.

  The consent carries `:sub`, `:brand_subtenant_id` (`nil` for the tenant itself), `:channel`, `:status` and `:source` in lowercase, `:consent_kind`, `:recipient_type`, `:sequence`, `:occurred_at`, `:text_version_digest` (raw bytes), `:evidence` (`ip` and `device`, or `nil`), `:iys_transaction_ref` and `:source_event_ref` (the event's `webhook-id`).
  """

  @doc "Handles a consent in one tenant environment; `{:rejected, reason}` marks the event rejected and an error retries it."
  @callback handle_consent(scope :: Relay.Scope.t(), consent :: map()) ::
              :ok | {:rejected, String.t()} | {:error, term()}
end
