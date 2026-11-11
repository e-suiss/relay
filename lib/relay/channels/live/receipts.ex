defmodule Relay.Channels.Live.Receipts do
  @moduledoc """
  The durable receipt path of SMS and e-mail provider webhooks (WH-49, L-17, INV-12, DS-22): receipt first, a fast `2xx`, processing from the queue.

    1. `accept/4` verifies the request on its raw body with the account's verification secret (`Relay.Channels.provider_webhook/3`) and reads its items. Each item is one provider event: a delivery report that is not pending or an e-mail event that names a delivery.
    2. Each item is a receipt `(tenant, environment, provider, provider_event_id)`, unique in the database (INV-12): the provider's own event identifier when it sends one (`email:<id>`), otherwise the SHA-256 of the item without its personal fields and its actor (`sha256:<hex>`). The item is sealed with the tenant's data key as the receipt body (retention class `delivery_record`). A repeated event is counted on its receipt and processed no further. The receipts and their processing jobs (`Relay.Channels.Live.ReceiptWorker`, at most 100 receipts each, identifiers only, T-15) are committed in one transaction before the provider is answered.
    3. `process/2`, run by the delivery report batcher (`Relay.Channels.Live.ReportBatcher`, T-41), reads a batch of receipts of one scope, opens each sealed item and records the events of the whole batch in one transaction through the evidence table (`Relay.Channels.Live.Events.record_many/2`), with the receipt's actor (`provider_webhook`, or `provider_api` for a reconciliation's items, `record/4`) and the receipt on each ledger entry, so a receipt becomes `processed` with its ledger entry. A report whose delivery is unknown or whose body cannot be read is `rejected`; an e-mail event without a classification is `processed` with no entry. The suppressions and telemetry of a recorded e-mail event follow the commit (`Relay.Channels.Live.EmailEvents`).
  """

  alias Relay.Channels.Live
  alias Relay.Channels.Live.EmailEvents
  alias Relay.Channels.Live.Events
  alias Relay.Channels.Live.ReceiptWorker
  alias Relay.Channels.Live.Store
  alias Relay.Scope

  @per_job 100
  @types %{
    "delivered" => :delivered,
    "bounced" => :bounced,
    "deferred" => :deferred,
    "complained" => :complained,
    "rejected" => :rejected,
    "engagement" => :engagement
  }
  @unhashed ["recipient", "diagnostic", "actor"]
  @recorded [:applied, :stale_ignored, :conflict_flagged]

  @type accepted :: %{recorded: non_neg_integer(), duplicates: non_neg_integer()}

  # WH-49
  # INV-12
  # L-17
  # T-40
  @doc "Verifies a provider webhook request of an account (`%{\"id\", \"provider\"}`) with its verification secret and commits its receipts and their jobs; see the module documentation. Returns how many receipts were recorded and how many events were repeats, the verification error, or `{:error, :unavailable}` when nothing could be committed."
  @spec accept(Scope.t(), map(), Relay.Redacted.t(), Relay.Channels.webhook_request()) ::
          {:ok, accepted()} | {:error, Relay.Channels.webhook_reason() | :unavailable}
  def accept(%Scope{} = scope, %{"provider" => provider} = account, key, request) do
    with {:ok, items} <- Relay.Channels.provider_webhook(provider, key, request) do
      commit(scope, account, :crypto.hash(:sha256, request.body), items, :provider_webhook)
    end
  end

  # DS-22
  # DS-48
  # INV-12
  @doc "Commits the items a reconciliation read from a provider's status or event list API (`actor = provider_api`) as receipts with their jobs, exactly as a webhook's items, so an event already received through the webhook is a repeat and is counted, not written again."
  @spec record(Scope.t(), map(), [Relay.Channels.webhook_item()], :provider_api) ::
          {:ok, accepted()} | {:error, :unavailable}
  def record(%Scope{} = scope, %{"provider" => _provider} = account, items, :provider_api) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(Enum.map(items, &encode/1)))
    commit(scope, account, digest, items, :provider_api)
  end

  defp commit(_scope, _account, _digest, [], _actor), do: {:ok, %{recorded: 0, duplicates: 0}}

  defp commit(scope, account, digest, items, actor) do
    with {:ok, key_id} <- Relay.Tenancy.active_tenant_key(scope, :data),
         {:ok, sealed} <- seal(scope, key_id, items, actor),
         {:ok, counts} <- write(scope, account, digest, key_id, sealed) do
      {:ok, counts}
    else
      _failed -> {:error, :unavailable}
    end
  end

  defp seal(scope, key_id, items, actor) do
    field = field(scope, key_id)

    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      encoded = Map.put(encode(item), "actor", Atom.to_string(actor))

      case Relay.Tenancy.encrypt_field(field, Jason.encode!(encoded)) do
        {:ok, ct} -> {:cont, {:ok, [{event_id(item, encoded), ct} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reversed()
  end

  defp reversed({:ok, list}), do: {:ok, Enum.reverse(list)}
  defp reversed(error), do: error

  defp write(scope, account, digest, key_id, sealed),
    do: Store.in_scope(scope, fn _status -> record(scope, account, digest, key_id, sealed) end)

  defp record(scope, account, digest, key_id, sealed) do
    ids =
      for {event_id, ct} <- sealed,
          {:recorded, id} <- [receipt(account, event_id, digest, ct, key_id)],
          do: id

    ids |> Enum.chunk_every(@per_job) |> Enum.each(&enqueue(scope, &1))
    %{recorded: length(ids), duplicates: length(sealed) - length(ids)}
  end

  defp receipt(account, event_id, digest, ct, key_id) do
    Relay.Webhooks.receipt_record(%{
      id: Relay.Id.generate(),
      provider: account["provider"],
      provider_account_id: account["id"],
      provider_event_id: event_id,
      body_digest: digest,
      body_ct: ct,
      body_key_id: key_id
    })
  end

  defp enqueue(scope, ids) do
    job = %{
      id: Relay.Id.generate(),
      lane: Relay.Platform.lane(:transactional),
      worker: ReceiptWorker,
      args: ReceiptWorker.args(scope, ids),
      ref_kind: "webhook_receipt",
      ref_id: hd(ids)
    }

    case Relay.Platform.enqueue_job(job) do
      {:ok, _queued} -> :ok
      {:error, error} -> Store.rollback(error)
    end
  end

  defp field(scope, key_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :delivery_record,
      table: "webhook_receipts",
      column: "body_ct",
      key_id: key_id
    }
  end

  defp encode({:report, report}) do
    {result, code} =
      case report.result do
        {:delivered, _info} -> {"delivered", nil}
        {:rejected, raw} -> {"rejected", raw.code}
      end

    %{
      "kind" => "report",
      "channel" => report.channel,
      "result" => result,
      "code" => code,
      "correlation" => Map.get(report, :correlation),
      "provider_message_id" => report.provider_message_id,
      "occurred_at" => time(Map.get(report, :occurred_at)),
      "detail" => Map.get(report, :detail) || %{}
    }
  end

  defp encode({:email, event}) do
    %{
      "kind" => "email",
      "type" => Atom.to_string(event.type),
      "code" => event.code,
      "id" => event.id,
      "delivery_id" => Relay.Id.to_string(event.delivery_id),
      "provider_message_id" => event.provider_message_id,
      "recipient" => exposed(event.recipient),
      "occurred_at" => time(event.occurred_at),
      "status" => event.status,
      "diagnostic" => exposed(event.diagnostic)
    }
  end

  defp event_id({:email, %{id: id}}, _encoded) when is_binary(id) and id != "",
    do: String.slice("email:" <> id, 0, 512)

  defp event_id(_item, encoded) do
    binary = encoded |> Map.drop(@unhashed) |> :erlang.term_to_binary([:deterministic])
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, binary), case: :lower)
  end

  defp time(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp time(_none), do: nil

  defp exposed(nil), do: nil
  defp exposed(value), do: Relay.Redacted.expose(value)

  # WH-49
  # T-41
  # DS-10
  @doc "Processes receipts of one scope as one batch; see the module documentation. A receipt that is no longer `received` is skipped; a failure that may pass, such as an unavailable key or database, returns an error and the batch is tried again."
  @spec process(Scope.t(), [Relay.Id.t()]) :: :ok | {:error, term()}
  def process(%Scope{} = scope, receipt_ids) when is_list(receipt_ids) do
    read = fn _status -> Enum.map(receipt_ids, &Relay.Webhooks.receipt/1) end

    with {:ok, rows} <- Store.in_scope(scope, read),
         {:ok, declarations} <- Relay.Datasets.channel_declarations(),
         {:ok, table} <- EmailEvents.table(),
         {:ok, planned} <- plan_all(scope, declarations, table, rows) do
      record(scope, planned)
    end
  end

  defp plan_all(scope, declarations, table, rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn
      %{"state" => "received"} = row, {:ok, acc} ->
        case plan(scope, declarations, table, row) do
          {:error, reason} -> {:halt, {:error, reason}}
          planned -> {:cont, {:ok, [planned | acc]}}
        end

      _final_or_missing, acc ->
        {:cont, acc}
    end)
    |> reversed()
  end

  defp plan(scope, declarations, table, row) do
    case Relay.Tenancy.decrypt_field(field(scope, row["body_key_id"]), row["body_ct"]) do
      {:ok, plain} -> item(declarations, table, row, Jason.decode(Relay.Redacted.expose(plain)))
      {:error, reason} -> {:error, reason}
    end
  end

  defp item(declarations, _table, row, {:ok, %{"kind" => "report"} = item}) do
    case Live.report_event(declarations, row["provider"], report(item), actor(item)) do
      {:ok, event} -> {:event, Map.put(event, :receipt_id, row["id"]), nil}
      {:error, reason} -> {:mark, row["id"], :rejected, Atom.to_string(reason)}
    end
  end

  defp item(declarations, table, row, {:ok, %{"kind" => "email"} = item}) do
    with {:ok, event} <- email(row["provider"], item),
         {:ok, fields, actions} <- EmailEvents.prepare(declarations, table, event) do
      fields = Map.merge(fields, %{receipt_id: row["id"], actor: actor(item)})
      {:event, fields, {event, actions}}
    else
      {:skipped, :no_classification} -> {:mark, row["id"], :processed, nil}
      {:skipped, reason} -> {:mark, row["id"], :rejected, Atom.to_string(reason)}
      _unreadable -> {:mark, row["id"], :rejected, "unreadable"}
    end
  end

  defp item(_declarations, _table, row, _unreadable),
    do: {:mark, row["id"], :rejected, "unreadable"}

  defp actor(%{"actor" => "provider_api"}), do: :provider_api
  defp actor(_item), do: :provider_webhook

  defp report(item) do
    result =
      case item["result"] do
        "delivered" -> {:delivered, %{}}
        _rejected -> {:rejected, %{code: to_string(item["code"])}}
      end

    %{
      provider_message_id: item["provider_message_id"],
      result: result,
      channel: item["channel"],
      correlation: item["correlation"],
      occurred_at: parse_time(item["occurred_at"]),
      detail: item["detail"] || %{}
    }
  end

  defp email(provider, item) do
    with {:ok, type} <- Map.fetch(@types, item["type"]),
         {:ok, delivery_id} <- Relay.Id.parse(to_string(item["delivery_id"])) do
      event =
        Relay.Channels.email_event(%{
          provider: provider,
          type: type,
          code: to_string(item["code"]),
          id: item["id"],
          delivery_id: delivery_id,
          provider_message_id: item["provider_message_id"],
          recipient: redacted(item["recipient"]),
          occurred_at: parse_time(item["occurred_at"]),
          status: item["status"],
          diagnostic: redacted(item["diagnostic"])
        })

      {:ok, event}
    end
  end

  defp redacted(nil), do: nil
  defp redacted(value), do: Relay.Redacted.wrap(value)

  defp parse_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _invalid -> nil
    end
  end

  defp parse_time(_none), do: nil

  defp record(scope, planned) do
    events = for {:event, event, _post} <- planned, do: event
    posts = for {:event, _event, post} <- planned, do: post
    marks = for {:mark, id, state, reason} <- planned, do: {id, state, reason}

    with {:ok, _marked} <- mark(scope, marks),
         {:ok, results} <- Events.record_many(scope, events) do
      posts |> Enum.zip(results) |> Enum.each(&follow(scope, &1))
    end
  end

  defp mark(_scope, []), do: {:ok, []}

  defp mark(scope, marks) do
    Store.in_scope(scope, fn _status ->
      for {id, state, reason} <- marks, do: Relay.Webhooks.receipt_mark(id, state, reason)
    end)
  end

  defp follow(scope, {{%{} = event, actions}, {:ok, %{result: result}}})
       when result in @recorded,
       do: EmailEvents.apply_actions(scope, event, actions)

  defp follow(_scope, _post), do: :ok
end
