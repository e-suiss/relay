defmodule Relay.Webhooks.Completions do
  @moduledoc """
  The receiver of long-running job completion notifications (WH-68, WH-50, E-48). A registered source posts a notification of the Suiss webhook profile to its own endpoint; the acceptance rules are those of a provider webhook (WH-49): the request is verified on its raw body, committed as a receipt with its processing job, and only then answered.

    1. `accept/3` reads the source, which must be active, and its key: the `whpk_` public key of a `v1a` source, or the `whsec_` secret a `v1` source's secret reference resolves to for this request only (TN-26). The request is verified with the one verifier of the profile (`Relay.Webhooks.verify_message/4`); a request that does not verify is refused and nothing is written.
    2. The verified body must be a notification (`parse/1`): a structured CloudEvents 1.0 envelope whose `type` is `job.completed` or `job.failed` and whose `data` names a waitpoint and may carry a small `result`.
    3. The raw body is sealed under the tenant's data key and committed as a receipt `(tenant, environment, "completion", "<source>:<webhook-id>")`, unique in the database, together with its job (`Relay.Webhooks.CompletionWorker`, identifiers only). A `webhook-id` the source sent before is counted on its receipt and processed no further; a receipt is never deleted, so an identifier is remembered beyond the 96 hours of the profile.
    4. `process/2`, run from the queue, opens the sealed body and completes the waitpoint it names through the port. A waitpoint that is unknown, already closed, or not an event waitpoint without a condition is left as it is: the notification was accepted and has no effect. The receipt is then `processed`; one whose body can no longer be read as a notification is `rejected`.

  The module is also the port through which the receiver uses the rest of a running node (`config :relay, Relay.Webhooks, completion_port: Module`, `Relay.Webhooks.Live` by default): the secret backend, the job queue and the waitpoints of `Relay.Agents`.
  """

  alias Relay.Redacted
  alias Relay.Scope
  alias Relay.Webhooks.EngineStore
  alias Relay.Webhooks.Profile
  alias Relay.Webhooks.Settings
  alias Relay.Webhooks.SourceStore
  alias Relay.Webhooks.Store

  @provider "completion"
  @field {"webhook_receipts", "body_ct"}
  @result_field {"waitpoint_completions", "result_ct"}
  @outcomes %{"job.completed" => :completed, "job.failed" => :failed}
  @data_keys ["waitpoint_id", "result"]
  @result_max Relay.Limits.fetch!(["webhook", "completion_result_max_bytes"])

  @type request :: %{
          required(:body) => binary(),
          required(:headers) => Profile.headers(),
          required(:now) => DateTime.t()
        }
  @type refusal :: :not_found | :unauthorized | :malformed | :unavailable
  @type notification :: %{
          outcome: :completed | :failed,
          waitpoint_id: Relay.Id.t(),
          result: map() | nil
        }
  @type result :: %{outcome: String.t(), result: map() | nil, completed_at: DateTime.t()}
  @type completion :: :resolved | :expired | :already_terminal | :not_found | :not_completable

  @doc "Resolves the secret of a source from its secret reference for this call only: `:none` when the reference is not an active one of kind `webhook_signing`, `:unavailable` when the secret backend cannot be read."
  @callback source_secret(Scope.t(), Relay.Id.t()) :: {:ok, Redacted.t()} | :none | :unavailable

  @doc "Queues the processing job of a receipt inside the caller's scoped transaction."
  @callback enqueue_completion(Scope.t(), Relay.Id.t()) :: :ok | {:error, term()}

  @doc "Completes the event waitpoint with this identifier and records the completion (`:receipt_id`, `:outcome` and the sealed result as `:result_ct` and `:result_key_id`) with it, in one transaction of its own."
  @callback complete_waitpoint(Scope.t(), Relay.Id.t(), map()) ::
              {:ok, completion()} | {:error, term()}

  @doc "Reads the completion that resolved a waitpoint, its result still sealed, or `nil`."
  @callback waitpoint_completion(Scope.t(), Relay.Id.t()) :: {:ok, map() | nil} | {:error, term()}

  # WH-68
  # WH-49
  # WH-50
  # T-40
  @doc "Verifies a notification of the source `source_id` and commits its receipt and job; see the module documentation. `:recorded` and `:duplicate` are both acknowledged to the source."
  @spec accept(Scope.t(), Relay.Id.t(), request()) ::
          {:ok, :recorded | :duplicate} | {:error, refusal()}
  def accept(%Scope{} = scope, source_id, %{body: body, headers: headers, now: now})
      when is_binary(body) do
    with {:ok, source} <- source(scope, source_id),
         {:ok, key} <- key(scope, source),
         {:ok, webhook_id} <- verify(headers, body, key, now),
         {:ok, _notification} <- parse(body),
         {:ok, sealed} <- seal(scope, body) do
      commit(scope, receipt(source_id, webhook_id, body, sealed))
    end
  end

  defp source(scope, source_id) do
    case SourceStore.in_scope(scope, &{&1, SourceStore.get(source_id)}) do
      {:ok, {:active, %{"state" => "active"} = source}} -> {:ok, source}
      {:ok, {:suspended, %{"state" => "active"}}} -> {:error, :unavailable}
      {:ok, _closed_archived_or_missing} -> {:error, :not_found}
      {:error, %Relay.Error{code: :not_found}} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  # TN-26
  defp key(_scope, %{"scheme" => "v1a", "public_key" => <<_::256>> = public_key}),
    do: {:ok, Profile.public_key_text(public_key)}

  defp key(scope, %{"scheme" => "v1", "secret_ref_id" => ref_id}) do
    case port().source_secret(scope, ref_id) do
      {:ok, secret} -> {:ok, secret}
      :none -> {:error, :unauthorized}
      :unavailable -> {:error, :unavailable}
    end
  end

  # WH-50
  # T-40
  defp verify(headers, body, key, now) do
    case Relay.Webhooks.verify_message(headers, body, [key], now) do
      {:ok, %{id: webhook_id}} -> {:ok, webhook_id}
      {:error, _rejection} -> {:error, :unauthorized}
    end
  end

  # WH-68
  @doc "Reads a notification from the bytes of its body: the outcome its `type` names and the waitpoint its `data` references. Other CloudEvents attributes are ignored; a `data` with another field, or a `result` above the `completion_result_max_bytes` limit, is not a notification."
  @spec parse(binary()) :: {:ok, notification()} | {:error, :malformed}
  def parse(body) when is_binary(body) do
    with {:ok, %{"specversion" => "1.0", "data" => %{} = data} = event} <- Jason.decode(body),
         true <- envelope?(event),
         {:ok, outcome} <- Map.fetch(@outcomes, event["type"]),
         true <- data?(data),
         {:ok, waitpoint_id} <- reference(data["waitpoint_id"]) do
      {:ok, %{outcome: outcome, waitpoint_id: waitpoint_id, result: Map.get(data, "result")}}
    else
      _other -> {:error, :malformed}
    end
  end

  defp envelope?(event) do
    Enum.all?([
      text?(event["id"], 512),
      text?(event["source"], 1024),
      Map.get(event, "datacontenttype", "application/json") == "application/json",
      time?(Map.get(event, "time"))
    ])
  end

  defp text?(value, max), do: is_binary(value) and value != "" and String.length(value) <= max

  defp time?(nil), do: true

  defp time?(text) when is_binary(text),
    do: match?({:ok, _at, _offset}, DateTime.from_iso8601(text))

  defp time?(_other), do: false

  defp data?(data), do: Map.keys(data) -- @data_keys == [] and result?(Map.get(data, "result"))

  defp result?(nil), do: true
  defp result?(%{} = result), do: byte_size(Jason.encode!(result)) <= @result_max
  defp result?(_other), do: false

  defp reference(text) when is_binary(text) do
    case Relay.ExternalId.decode(text, ["wp"]) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> :error
    end
  end

  defp reference(_other), do: :error

  defp seal(scope, body) do
    case Settings.sealer().seal(scope, @field, body) do
      {:ok, sealed} -> {:ok, sealed}
      {:error, _error} -> {:error, :unavailable}
    end
  end

  # WH-49 (3)
  # INV-12
  defp receipt(source_id, webhook_id, body, sealed) do
    %{
      id: Relay.Id.generate(),
      provider: @provider,
      provider_event_id: Relay.ExternalId.encode("whs", source_id) <> ":" <> webhook_id,
      body_digest: :crypto.hash(:sha256, body),
      body_ct: sealed.ct,
      body_key_id: sealed.key_id
    }
  end

  # WH-49 (1)
  defp commit(scope, receipt) do
    work = fn _status ->
      case Store.receipt_record(receipt) do
        {:recorded, id} -> queued(scope, id)
        {:duplicate, _id} -> :duplicate
      end
    end

    case SourceStore.in_scope(scope, work) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp queued(scope, receipt_id) do
    case port().enqueue_completion(scope, receipt_id) do
      :ok -> :recorded
      {:error, reason} -> EngineStore.rollback(reason)
    end
  end

  # WH-68
  # WH-49 (1)
  @doc "Processes the receipt of a notification: completes the waitpoint it names and marks the receipt. Returns what became of the waitpoint, `:skipped` for a receipt that is not waiting to be processed and `:unreadable` for a body that is not a notification; a failure that may pass is an error, and the job tries again."
  @spec process(Scope.t(), Relay.Id.t()) ::
          {:ok, completion() | :skipped | :unreadable} | {:error, term()}
  def process(%Scope{} = scope, receipt_id) do
    with {:ok, %{"state" => "received", "provider" => @provider} = receipt} <-
           SourceStore.in_scope(scope, fn _status -> Store.receipt(receipt_id) end),
         {:ok, raw} <- open(scope, receipt) do
      settle(scope, receipt_id, parse(Redacted.expose(raw)))
    else
      {:ok, _final_missing_or_other} -> {:ok, :skipped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open(scope, %{"body_key_id" => <<_::128>> = key_id, "body_ct" => ct}) when is_binary(ct),
    do: Settings.sealer().open(scope, @field, key_id, ct)

  defp open(_scope, _receipt), do: {:ok, Redacted.wrap("")}

  defp settle(scope, receipt_id, {:ok, %{waitpoint_id: waitpoint_id} = notification}) do
    with {:ok, sealed} <- sealed_result(scope, notification.result),
         completion = Map.merge(sealed, %{receipt_id: receipt_id, outcome: notification.outcome}),
         {:ok, result} <- port().complete_waitpoint(scope, waitpoint_id, completion),
         {:ok, _marked} <- mark(scope, receipt_id, :processed, nil) do
      :ok = counted(result)
      {:ok, result}
    end
  end

  defp settle(scope, receipt_id, {:error, :malformed}) do
    with {:ok, _marked} <- mark(scope, receipt_id, :rejected, "unreadable") do
      :ok = counted(:unreadable)
      {:ok, :unreadable}
    end
  end

  # TN-27
  defp sealed_result(_scope, nil), do: {:ok, %{result_ct: nil, result_key_id: nil}}

  defp sealed_result(scope, %{} = result) do
    with {:ok, %{ct: ct, key_id: key_id}} <-
           Settings.sealer().seal(scope, @result_field, Jason.encode!(result)),
         do: {:ok, %{result_ct: ct, result_key_id: key_id}}
  end

  defp counted(result) do
    :telemetry.execute([:relay, :webhooks, :completion], %{count: 1}, %{result: result})
  end

  # WH-68
  # TN-27
  @doc "Reads what a completion notification said about the job a waitpoint waited for: the `:outcome` (`completed` or `failed`), the `:result` object it carried, opened here from its sealed form, and `:completed_at`. `nil` for a waitpoint that no completion notification resolved. It is the answer of an authorised read of the waitpoint and is never part of an event; it runs outside any transaction."
  @spec result(Scope.t(), Relay.Id.t()) :: {:ok, result() | nil} | {:error, term()}
  def result(%Scope{} = scope, waitpoint_id) do
    case port().waitpoint_completion(scope, waitpoint_id) do
      {:ok, nil} -> {:ok, nil}
      {:ok, %{} = completion} -> opened(scope, completion)
      {:error, reason} -> {:error, reason}
    end
  end

  defp opened(_scope, %{result_ct: nil} = completion), do: {:ok, read(completion, nil)}

  defp opened(scope, %{result_ct: ct, result_key_id: key_id} = completion) do
    with {:ok, plain} <- Settings.sealer().open(scope, @result_field, key_id, ct),
         {:ok, %{} = result} <- Jason.decode(Redacted.expose(plain)) do
      {:ok, read(completion, result)}
    else
      {:ok, _not_an_object} -> {:error, :unreadable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read(completion, result),
    do: %{outcome: completion.outcome, result: result, completed_at: completion.completed_at}

  defp mark(scope, receipt_id, state, reason) do
    SourceStore.in_scope(scope, fn _status -> Store.receipt_mark(receipt_id, state, reason) end)
  end

  defp port do
    :relay
    |> Application.get_env(Relay.Webhooks, [])
    |> Keyword.get(:completion_port, Relay.Webhooks.Live)
  end
end
