defmodule Relay.Webhooks.Live do
  @moduledoc """
  The webhook engine on a running node.

  It is the sealer of `Relay.Webhooks` (`config :relay, Relay.Webhooks, sealer: Module`), which keeps signing key labels, HMAC secrets, operations contact addresses and the stored answers of delivery attempts encrypted under the tenant's `data` key (TN-27, TN-32). A value is sealed for the table and column that store it, in the delivery log's retention class, so it opens nowhere else and destroying the tenant's data key shreds it.

  It is the handler of the outbox dispatcher (`config :relay, Relay.Platform.Outbox, handler: {Relay.Webhooks.Live, :outbox_jobs}`): every outbox event becomes one webhook event with one message for each subscribed endpoint, in the dispatch transaction (OP-7, WH-2).

  And it is the runtime of the delivery engine (`Relay.Webhooks`): the engine's jobs enter the `l2` lane through the tenant wait table, so tenants share the lane fairly and none has a queue of its own (WH-38 (3)); an endpoint's concurrency is a cluster-wide slot counter and its rate a GCRA limit of the platform (WH-38 (1)); the snapshot fields of an event are read from its outbox row; and an operations e-mail is sent as the platform tenant, through the first verified e-mail account of the installation tenant with the configured sender as its `from` (WH-56). Such an e-mail is not a delivery: no attempt or ledger entry is written for it.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Agents,
      Relay.Channels,
      Relay.Datasets,
      Relay.Platform,
      Relay.Secrets,
      Relay.Tenancy,
      Relay.Webhooks
    ],
    exports: []

  @behaviour Relay.Webhooks

  alias Relay.Scope

  @type field :: {table :: String.t(), column :: String.t()}

  @call_ms 10_000
  @cancel_rule "webhook.message.cancelled"

  # TN-27
  # TN-32
  @doc "Seals `plaintext` for `field` under the scope's active `data` key. Runs outside any transaction."
  @spec seal(Scope.t(), field(), binary() | Relay.Redacted.t()) ::
          {:ok, %{ct: binary(), key_id: Relay.Id.t()}} | {:error, Relay.Error.t()}
  def seal(%Scope{} = scope, {table, column}, plaintext) do
    with {:ok, key_id} <- Relay.Tenancy.active_tenant_key(scope, :data),
         field = field(scope, table, column, key_id),
         {:ok, ct} <- Relay.Tenancy.encrypt_field(field, plaintext) do
      {:ok, %{ct: ct, key_id: key_id}}
    end
  end

  # TN-27
  # TN-32
  @doc "Opens a value sealed by `seal/3` for the same `field` under the tenant key `key_id`; the plaintext comes back redacted. Runs outside any transaction."
  @spec open(Scope.t(), field(), Relay.Id.t(), binary()) ::
          {:ok, Relay.Redacted.t()} | {:error, Relay.Error.t()}
  def open(%Scope{} = scope, {table, column}, <<_::128>> = key_id, ct) when is_binary(ct),
    do: Relay.Tenancy.decrypt_field(field(scope, table, column, key_id), ct)

  defp field(scope, table, column, key_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :delivery_record,
      table: table,
      column: column,
      key_id: key_id
    }
  end

  # OP-7
  # WH-1
  # WH-2
  # INV-12
  @doc "The handler of the outbox dispatcher: records the outbox event as a webhook event with its messages and their jobs inside the dispatch transaction. The jobs are queued here, so no job changeset is returned."
  @spec outbox_jobs(map()) :: [Ecto.Changeset.t()]
  def outbox_jobs(%{id: id, event_type: type, payload: payload} = event) do
    if Relay.EventCatalog.delivered?(type) do
      _created =
        Relay.Webhooks.deliver_event(%{
          id: id,
          type: type,
          data: Relay.Platform.outbox_data(payload),
          subject: event.stream_key,
          epoch: event.epoch,
          seq: event.seq,
          occurred_at: event.created_at,
          traceparent: event.traceparent
        })
    end

    []
  end

  # T-15
  # T-21
  # WH-38 (3)
  @impl Relay.Webhooks
  def enqueue(%{worker: worker, args: args, ref_id: ref_id} = job) do
    attrs = %{
      id: Relay.Id.generate(),
      lane: Relay.Platform.lane(:system),
      worker: worker,
      args: args,
      ref_kind: "webhook_job",
      ref_id: ref_id,
      scheduled_at: Map.get(job, :scheduled_at)
    }

    case Relay.Platform.enqueue_job(attrs) do
      {:ok, _queued} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # T-21 (3)
  @impl Relay.Webhooks
  def cancel(message_id) do
    {:ok, _count} = Relay.Platform.cancel_waiting_jobs("webhook_job", message_id, @cancel_rule)
    :ok
  end

  # T-22
  # WH-38 (1)
  @impl Relay.Webhooks
  def with_slot(%Scope{} = scope, endpoint_id, limit, holder, fun) do
    key = "cc.webhook_endpoint:" <> Relay.Id.to_string(endpoint_id)
    Relay.Platform.with_concurrency_slot(scope, key, limit, holder, fun)
  end

  # T-19
  # WH-38 (1)
  @impl Relay.Webhooks
  def rate(%Scope{} = scope, endpoint_id, per_second) do
    attrs = %{
      id: "webhook.endpoint",
      algorithm: :gcra,
      unit: :message,
      limit: per_second,
      period_ms: 1000,
      burst: per_second
    }

    parts = [Relay.Id.to_string(endpoint_id)]

    with {:ok, limit} <- Relay.Platform.rate_limit(attrs),
         {:deny, wait_ms, _rule} <-
           Relay.Platform.rate_limit_check(scope, limit, parts, 1, :l2) do
      {:deny, wait_ms}
    else
      _allowed_or_invalid -> :allow
    end
  end

  # WH-12
  @impl Relay.Webhooks
  def event_source(%Scope{} = scope, event_id, %DateTime{} = occurred_at) do
    case Relay.Platform.outbox_event_data(scope, event_id, occurred_at) do
      {:ok, %{} = data} -> data
      _missing -> nil
    end
  end

  # WH-19
  # TN-26
  @impl Relay.Webhooks
  def credential(%Scope{} = scope, ref_id) do
    case Relay.Secrets.get(scope, ref_id) do
      {:ok, %{kind: :webhook_destination, state: :active}} ->
        credentials(scope, %{"credential_ref_id" => ref_id})

      _other ->
        nil
    end
  end

  # WH-68
  # TN-26
  @doc "Resolves the secret of a completion source from its secret reference for this call only: `:none` when the reference is not an active one of kind `webhook_signing`, `:unavailable` when the secret backend cannot be read. Runs outside any transaction."
  @spec source_secret(Scope.t(), Relay.Id.t()) :: {:ok, Relay.Redacted.t()} | :none | :unavailable
  def source_secret(%Scope{} = scope, ref_id) do
    case Relay.Secrets.get(scope, ref_id) do
      {:ok, %{kind: :webhook_signing, state: :active}} -> fetched(scope, ref_id)
      {:ok, _other_kind_or_retired} -> :none
      {:error, _error} -> :unavailable
    end
  end

  defp fetched(scope, ref_id) do
    case Relay.Secrets.fetch(scope, ref_id) do
      {:ok, secret} -> {:ok, secret}
      {:error, %Relay.Error{code: :secret_retired}} -> :none
      {:error, _error} -> :unavailable
    end
  end

  # WH-68
  # WH-49 (1)
  # T-15
  @doc "Queues the job that processes the receipt of a completion notification, inside the caller's scoped transaction."
  @spec enqueue_completion(Scope.t(), Relay.Id.t()) :: :ok | {:error, term()}
  def enqueue_completion(%Scope{} = scope, receipt_id) do
    attrs = %{
      id: Relay.Id.generate(),
      lane: Relay.Platform.lane(:transactional),
      worker: Relay.Webhooks.CompletionWorker,
      args: Map.put(Scope.to_job_args(scope), "receipt_id", Relay.Id.to_string(receipt_id)),
      ref_kind: "webhook_receipt",
      ref_id: receipt_id
    }

    case Relay.Platform.enqueue_job(attrs) do
      {:ok, _queued} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # WH-68
  @doc "Completes the event waitpoint a completion notification names and records the completion with it, in one transaction of its own; see `Relay.Agents.complete_waitpoint/3`."
  @spec complete_waitpoint(Scope.t(), Relay.Id.t(), map()) :: {:ok, atom()} | {:error, term()}
  def complete_waitpoint(%Scope{} = scope, waitpoint_id, completion),
    do: Relay.Agents.complete_waitpoint(scope, waitpoint_id, completion)

  # WH-68
  @doc "Reads the completion that resolved a waitpoint, its result still sealed, or `nil`; see `Relay.Agents.waitpoint_completion/2`."
  @spec waitpoint_completion(Scope.t(), Relay.Id.t()) :: {:ok, map() | nil} | {:error, term()}
  def waitpoint_completion(%Scope{} = scope, waitpoint_id),
    do: Relay.Agents.waitpoint_completion(scope, waitpoint_id)

  # WH-56
  @impl Relay.Webhooks
  def mail(%Scope{}, addresses, %{from: from, subject: subject, text: text}) do
    platform = Relay.Datasets.installation_scope()
    policy = %{draw: 0, provider: nil, domestic_country: nil}

    with {:ok, declarations} <- Relay.Datasets.channel_declarations(),
         {:ok, {[account | _rest], _excluded}} <-
           Relay.Channels.routes(platform, "email", declarations, policy),
         {:ok, adapter} <- Relay.Channels.activated_adapter(declarations, account["provider"]) do
      content = %{"subject" => subject, "text" => text}
      base = %{scope: platform, account: account, content: content, from: from}
      Enum.reduce(addresses, :ok, &mailed(adapter, base, &1, &2))
    else
      {:ok, {[], _excluded}} -> {:error, :no_route}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mailed(adapter, base, address, result) do
    id = Relay.Id.generate()

    request =
      Relay.Channels.request(%{
        scope: base.scope,
        delivery_id: id,
        attempt_no: 1,
        channel: "email",
        provider: base.account["provider"],
        idempotency_key: "ops-" <> Relay.Id.to_string(id),
        target: %{kind: :address, id: nil, value: address},
        timeout_ms: @call_ms,
        content: base.content,
        credentials: credentials(base.scope, base.account),
        account: base.account,
        message_class: "system",
        overrides: %{"from" => base.from}
      })

    case adapter.deliver(request) do
      {:accepted, _detail} -> result
      other -> {:error, other}
    end
  end

  defp credentials(_scope, %{"credential_ref_id" => nil}), do: nil

  defp credentials(scope, %{"credential_ref_id" => ref_id}) do
    case Relay.Secrets.fetch(scope, ref_id) do
      {:ok, secret} -> secret
      {:error, _error} -> nil
    end
  end
end
