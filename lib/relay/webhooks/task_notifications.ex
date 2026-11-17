defmodule Relay.Webhooks.TaskNotifications do
  @moduledoc """
  The receiver of agent task notifications (AG-36, AG-37, AG-42, E-51, L-28, INV-35): the A2A push notifications a registered source posts to its own endpoint. What A2A leaves open, Relay takes from the Suiss webhook profile and the rules of a provider webhook (WH-49, WH-50): the request is verified on its raw body with the one verifier of the profile and the key of the source, committed as a receipt with its processing job, and only then answered.

    1. `accept/3` reads the source, which must be active, and its key, checks the `A2A-Version` header against the versions Relay serves and verifies the request. A request that does not verify, names another version or is no task notification is refused and nothing is written.
    2. The body must be an A2A `StreamResponse` that names a task and gives a sequence number (the port reads it). Its raw bytes are sealed under the tenant's data key and committed as a receipt `(tenant, environment, "a2a", "<source>:<task>:<seq>")`, unique in the database, together with its job: a notification of the same task and sequence number is counted on its receipt and processed no further, however often and under whatever `webhook-id` it is sent.
    3. `process/2`, run from the queue, applies the notification to the recorded state of the task through the port. A notification older than the recorded one changes nothing. When it arrived out of order or names no state, the task is read again at its source, since a notification is only a hint that the task changed.

  The module is also the port through which the receiver uses the rest of a running node (`config :relay, Relay.Webhooks, task_port: Module`, `Relay.Webhooks.Live` by default): the secret backend, the job queue and the A2A reading and task records of `Relay.Agents`.
  """

  alias Relay.Redacted
  alias Relay.Scope
  alias Relay.Webhooks.EngineStore
  alias Relay.Webhooks.Profile
  alias Relay.Webhooks.Settings
  alias Relay.Webhooks.SourceStore
  alias Relay.Webhooks.Store

  @provider "a2a"
  @field {"webhook_receipts", "body_ct"}
  @version_header "a2a-version"

  @type request :: %{
          required(:body) => binary(),
          required(:headers) => Profile.headers(),
          required(:now) => DateTime.t()
        }
  @type refusal ::
          :not_found | :unauthorized | :malformed | :unavailable | :version_not_supported
  @type notification :: %{task: String.t(), seq: non_neg_integer(), state: String.t() | nil}
  @type applied :: :applied | :duplicate | :stale | :source_not_found

  @doc "Resolves the secret of a source from its secret reference for this call only: `:none` when the reference is not an active one of kind `webhook_signing`, `:unavailable` when the secret backend cannot be read."
  @callback source_secret(Scope.t(), Relay.Id.t()) :: {:ok, Redacted.t()} | :none | :unavailable

  @doc "Checks the `A2A-Version` values of a request against the versions Relay serves."
  @callback task_version([String.t()]) :: {:ok, String.t()} | {:error, :version_not_supported}

  @doc "Reads a decoded body as a task notification: the task, its sequence number and the state it reports, or `:error`."
  @callback task_notification(term()) :: {:ok, notification()} | :error

  @doc "Queues the processing job of a receipt inside the caller's scoped transaction."
  @callback enqueue_task_notification(Scope.t(), Relay.Id.t()) :: :ok | {:error, term()}

  @doc "Applies a notification (`:source_id`, `:task`, `:seq`, `:state`, `:receipt_id`) to the recorded state of its task, in one transaction of its own."
  @callback apply_task_notification(Scope.t(), map()) :: {:ok, applied()} | {:error, term()}

  @doc "Reads a task again at its source and applies what the source reports."
  @callback reconcile_task(Scope.t(), Relay.Id.t(), String.t()) ::
              {:ok, atom()} | {:error, term()}

  # AG-42
  # AG-37
  # WH-49
  # WH-50
  @doc "Verifies a task notification of the source `source_id` and commits its receipt and job; see the module documentation. `:recorded` and `:duplicate` are both acknowledged to the source."
  @spec accept(Scope.t(), Relay.Id.t(), request()) ::
          {:ok, :recorded | :duplicate} | {:error, refusal()}
  def accept(%Scope{} = scope, source_id, %{body: body, headers: headers, now: now})
      when is_binary(body) do
    with {:ok, source} <- source(scope, source_id),
         {:ok, _version} <- version(headers),
         {:ok, key} <- key(scope, source),
         :ok <- verify(headers, body, key, now),
         {:ok, notification} <- parse(body),
         {:ok, sealed} <- seal(scope, body) do
      commit(scope, receipt(source_id, notification, body, sealed))
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

  # AG-42
  # E-50
  defp version(headers) do
    values = for {name, value} <- headers, String.downcase(name) == @version_header, do: value
    port().task_version(values)
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
  defp verify(headers, body, key, now) do
    case Relay.Webhooks.verify_message(headers, body, [key], now) do
      {:ok, _verified} -> :ok
      {:error, _rejection} -> {:error, :unauthorized}
    end
  end

  # AG-37
  # AG-42
  @doc "Reads a task notification from the bytes of its body, or `{:error, :malformed}`."
  @spec parse(binary()) :: {:ok, notification()} | {:error, :malformed}
  def parse(body) when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, notification} <- port().task_notification(decoded) do
      {:ok, notification}
    else
      _other -> {:error, :malformed}
    end
  end

  defp seal(scope, body) do
    case Settings.sealer().seal(scope, @field, body) do
      {:ok, sealed} -> {:ok, sealed}
      {:error, _error} -> {:error, :unavailable}
    end
  end

  # AG-37
  # INV-12
  defp receipt(source_id, %{task: task, seq: seq}, body, sealed) do
    source = Relay.ExternalId.encode("whs", source_id)

    %{
      id: Relay.Id.generate(),
      provider: @provider,
      provider_event_id: source <> ":" <> task <> ":" <> Integer.to_string(seq),
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
    case port().enqueue_task_notification(scope, receipt_id) do
      :ok -> :recorded
      {:error, reason} -> EngineStore.rollback(reason)
    end
  end

  # AG-37
  # INV-35
  # WH-49 (1)
  @doc "Processes the receipt of a task notification: applies it to the recorded state of its task, reads the task again at its source when the notification arrived out of order or names no state, and marks the receipt. Returns what became of the notification, `:skipped` for a receipt that is not waiting to be processed and `:unreadable` for a body that is no notification; a failure that may pass is an error, and the job tries again."
  @spec process(Scope.t(), Relay.Id.t()) ::
          {:ok, applied() | :skipped | :unreadable} | {:error, term()}
  def process(%Scope{} = scope, receipt_id) do
    with {:ok, %{"state" => "received", "provider" => @provider} = receipt} <-
           SourceStore.in_scope(scope, fn _status -> Store.receipt(receipt_id) end),
         {:ok, raw} <- open(scope, receipt) do
      settle(scope, receipt, parse(Redacted.expose(raw)))
    else
      {:ok, _final_missing_or_other} -> {:ok, :skipped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open(scope, %{"body_key_id" => <<_::128>> = key_id, "body_ct" => ct}) when is_binary(ct),
    do: Settings.sealer().open(scope, @field, key_id, ct)

  defp open(_scope, _receipt), do: {:ok, Redacted.wrap("")}

  defp settle(scope, %{"id" => receipt_id} = receipt, {:ok, notification}) do
    with {:ok, source_id} <- source_id(receipt),
         attrs = Map.merge(notification, %{source_id: source_id, receipt_id: receipt_id}),
         {:ok, result} <- port().apply_task_notification(scope, attrs),
         {:ok, _read} <- reconciled(scope, source_id, notification, result),
         {:ok, _marked} <- mark(scope, receipt_id, :processed, nil) do
      :ok = counted(result)
      {:ok, result}
    end
  end

  defp settle(scope, %{"id" => receipt_id}, {:error, :malformed}) do
    with {:ok, _marked} <- mark(scope, receipt_id, :rejected, "unreadable") do
      :ok = counted(:unreadable)
      {:ok, :unreadable}
    end
  end

  defp source_id(%{"provider_event_id" => event_id}) do
    [source | _task_and_seq] = String.split(event_id, ":", parts: 2)

    case Relay.ExternalId.decode(source, ["whs"]) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> {:error, :unreadable}
    end
  end

  # INV-35
  defp reconciled(scope, source_id, %{task: task}, :stale),
    do: port().reconcile_task(scope, source_id, task)

  defp reconciled(scope, source_id, %{task: task, state: nil}, :applied),
    do: port().reconcile_task(scope, source_id, task)

  defp reconciled(_scope, _source_id, _notification, _result), do: {:ok, :not_needed}

  defp counted(result) do
    :telemetry.execute([:relay, :webhooks, :task_notification], %{count: 1}, %{result: result})
  end

  defp mark(scope, receipt_id, state, reason) do
    SourceStore.in_scope(scope, fn _status -> Store.receipt_mark(receipt_id, state, reason) end)
  end

  defp port do
    :relay
    |> Application.get_env(Relay.Webhooks, [])
    |> Keyword.get(:task_port, Relay.Webhooks.Live)
  end
end
