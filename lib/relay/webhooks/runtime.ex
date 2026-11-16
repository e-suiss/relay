defmodule Relay.Webhooks.Runtime do
  @moduledoc """
  The port through which the delivery engine uses the rest of a running node (T-56): the job queue with its tenant fairness, the cluster-wide concurrency and rate limits, the source of an event's snapshot fields and the operations e-mail. It is configured as `config :relay, Relay.Webhooks, runtime: Module`; `Relay.Webhooks.Live` is the implementation of a running node.

  `c:enqueue/1` and `c:cancel/1` run inside the caller's scoped transaction, so a message and its job commit together. The other callbacks reach Valkey, the database or a provider on their own and never run inside a transaction.
  """

  alias Relay.Scope

  @typedoc "A job of the engine: `:worker`, `:args` (identifiers only), the `:message_id` or `:endpoint_id` it works for and, when it is not due at once, `:scheduled_at`."
  @type job :: %{
          required(:worker) => module(),
          required(:args) => map(),
          required(:ref_id) => Relay.Id.t(),
          optional(:scheduled_at) => DateTime.t() | nil
        }

  @typedoc "An operations e-mail: its sender address, its subject and its plain text."
  @type mail :: %{from: String.t(), subject: String.t(), text: String.t()}

  @doc "Queues a job inside the caller's scoped transaction."
  @callback enqueue(job()) :: :ok | {:error, term()}

  @doc "Cancels the waiting jobs of a message inside the caller's scoped transaction."
  @callback cancel(Relay.Id.t()) :: :ok

  @doc "Runs `fun` while holding one of the `limit` concurrency slots of an endpoint for `holder`, or answers `{:full, wait_ms}` without running it."
  @callback with_slot(Scope.t(), Relay.Id.t(), pos_integer(), String.t(), (-> term())) ::
              {:ok, term()} | {:full, non_neg_integer()}

  @doc "Spends one delivery of an endpoint's rate of `per_second`, or answers the wait in milliseconds."
  @callback rate(Scope.t(), Relay.Id.t(), pos_integer()) :: :allow | {:deny, pos_integer()}

  @doc "The data of the outbox event behind an event, with the identifiers in their external form, from which snapshot fields are taken; `nil` when it is no longer kept."
  @callback event_source(Scope.t(), Relay.Id.t(), DateTime.t()) :: map() | nil

  @doc "Sends an operations e-mail to the tenant's contacts through the platform tenant's e-mail channel."
  @callback mail(Scope.t(), [Relay.Redacted.t(), ...], mail()) :: :ok | {:error, term()}
end
