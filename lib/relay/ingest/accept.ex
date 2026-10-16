defmodule Relay.Ingest.Accept do
  @moduledoc """
  The accept path as one transaction (OP-7): tenant context, idempotency claim, one notification per recipient, its deliveries with their opening ledger events, a queue job per delivery to send, outbox events, and the stored idempotent response. All of it commits together or none of it does. Nothing here calls the network; the response body is sealed by the caller's `:seal` function, which must work from keys already in memory.

  A request is a map with:

    * `:endpoint`, `:idempotency_key`, `:fingerprint` — the idempotency scope (API-11, API-13);
    * `:notifications` — maps for `Relay.Ingest.Store.notification_accept/1`, each with `:deliveries`, maps for `Relay.Ingest.Store.delivery_open/2`;
    * `:outbox` — maps for `Relay.Ingest.Store.outbox_append/1`;
    * `:worker` — the `Oban.Worker` that sends a delivery; its arguments carry identifiers only (T-15);
    * `:respond` — builds `{status, headers, body}` from the accepted notifications;
    * `:seal` — encrypts the response body, returning `{:ok, {body_ct, body_key_id}}`.
  """

  alias Ecto.Multi
  alias Relay.Ingest.Idempotency
  alias Relay.Ingest.Store
  alias Relay.Scope

  @type outcome :: %{
          notifications: [map()],
          outbox: [%{stream_key: String.t(), epoch: integer(), seq: integer()}],
          response: {100..599, map(), binary()},
          stored: :stored | :not_cacheable
        }

  @type replay :: %{replayed: Store.response()}

  # INV-2
  # OP-7
  # T-15
  # T-57 (4)
  @doc """
  Runs the accept transaction. Returns the outcome, or `{:ok, %{replayed: response}}` for a replay of an earlier response; the stored body is still sealed. A key in progress, a key reused with a different body and an inactive tenant are errors; nothing is written for them.
  """
  @spec run(Scope.t(), map()) :: {:ok, outcome() | replay()} | {:error, Relay.Error.t()}
  def run(%Scope{} = scope, request) do
    case Store.in_scope_multi(scope, multi(scope, request)) do
      {:ok, changes} -> {:ok, outcome(changes)}
      {:error, :idempotency, {:replayed, response}, _changes} -> {:ok, %{replayed: response}}
      {:error, _step, %Relay.Error{} = error, _changes} -> {:error, error}
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, step, _reason, _changes} -> {:error, failed(step)}
    end
  end

  @dialyzer {:no_opaque, multi: 2}
  @doc "Builds the accept steps that follow the tenant context; run them only through `run/2`."
  @spec multi(Scope.t(), map()) :: Multi.t()
  def multi(%Scope{} = scope, request) do
    Multi.new()
    |> Multi.run(:active, fn _repo, %{tenant_status: status} -> active(status) end)
    |> Multi.run(:idempotency, fn _repo, _changes -> claim(request) end)
    |> Multi.run(:notifications, fn _repo, _changes -> accept_all(scope, request) end)
    |> Multi.run(:outbox, fn _repo, _changes -> append_outbox(request) end)
    |> Multi.run(:stored, fn _repo, changes -> complete(request, changes) end)
  end

  # TN-10
  defp active(:active), do: {:ok, :active}

  defp active(status),
    do: {:error, Relay.Error.new(:tenant_inactive, "tenant is not active", %{status: status})}

  defp claim(request) do
    case Store.idempotency_begin(request.endpoint, request.idempotency_key, request.fingerprint) do
      {:created, nil} -> {:ok, :created}
      {:replayed, response} -> {:error, {:replayed, response}}
      {claim, nil} -> {:error, Idempotency.claim_error(claim)}
    end
  end

  defp accept_all(scope, request) do
    request.notifications
    |> Enum.reduce_while({:ok, []}, fn notification, {:ok, acc} ->
      case accept_one(scope, request.worker, notification) do
        {:ok, accepted} -> {:cont, {:ok, [accepted | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, accepted} -> {:ok, Enum.reverse(accepted)}
      error -> error
    end
  end

  # API-16
  # TN-5
  defp accept_one(scope, worker, notification) do
    case Store.notification_accept(notification) do
      {:created, id} ->
        open_deliveries(scope, worker, id, :created, notification.deliveries)

      {:duplicate, id} ->
        {:ok, %{id: id, result: :duplicate, deliveries: []}}

      {:recipient_not_found, nil} ->
        {:ok, %{id: nil, result: :recipient_not_found, deliveries: []}}

      {:subtenant_not_found, nil} ->
        scope_mismatch(scope, worker, notification)

      {:tenant_inactive, nil} ->
        {:error, Relay.Error.new(:tenant_inactive, "tenant is not active")}
    end
  end

  defp scope_mismatch(scope, worker, notification) do
    case Store.notification_accept(Map.put(notification, :subtenant_id, nil)) do
      {:created, id} ->
        deliveries = Enum.map(notification.deliveries, &skip_scope_mismatch/1)
        open_deliveries(scope, worker, id, :scope_mismatch, deliveries)

      {:duplicate, id} ->
        {:ok, %{id: id, result: :duplicate, deliveries: []}}

      {other, _id} ->
        {:error, Relay.Error.new(:accept_failed, "notification not accepted", %{result: other})}
    end
  end

  defp skip_scope_mismatch(delivery) do
    Map.merge(delivery, %{
      decision: :skip,
      decision_reason: "scope_mismatch",
      decision_rule_id: "TN-5",
      deferred_until: nil
    })
  end

  defp open_deliveries(scope, worker, notification_id, result, deliveries) do
    deliveries
    |> Enum.reduce_while({:ok, []}, fn delivery, {:ok, acc} ->
      case open_delivery(scope, worker, notification_id, delivery) do
        {:ok, opened} -> {:cont, {:ok, [opened | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, opened} ->
        {:ok, %{id: notification_id, result: result, deliveries: Enum.reverse(opened)}}

      error ->
        error
    end
  end

  defp open_delivery(scope, worker, notification_id, delivery) do
    case Store.delivery_open(notification_id, delivery) do
      {:opened, id} ->
        with :ok <- enqueue(scope, worker, notification_id, id, delivery.decision) do
          {:ok, %{id: id, result: :opened, decision: delivery.decision}}
        end

      {:exists, id} ->
        {:ok, %{id: id, result: :exists, decision: delivery.decision}}

      {other, nil} ->
        {:error, Relay.Error.new(:accept_failed, "delivery not opened", %{result: other})}
    end
  end

  # T-15
  defp enqueue(scope, worker, notification_id, delivery_id, :send) do
    args =
      scope
      |> Scope.to_job_args()
      |> Map.merge(%{
        "notification_id" => uuid(notification_id),
        "delivery_id" => uuid(delivery_id)
      })

    case Oban.insert(worker.new(args)) do
      {:ok, _job} -> :ok
      {:error, _reason} -> {:error, Relay.Error.new(:accept_failed, "delivery job not queued")}
    end
  end

  defp enqueue(_scope, _worker, _notification_id, _delivery_id, _decision), do: :ok

  defp append_outbox(request) do
    {:ok,
     for event <- Map.get(request, :outbox, []) do
       {:appended, epoch, seq} = Store.outbox_append(event)
       %{stream_key: event.stream_key, epoch: epoch, seq: seq}
     end}
  end

  # API-14
  defp complete(request, changes) do
    {status, headers, body} = request.respond.(changes.notifications)

    with {:ok, {body_ct, body_key_id}} <- request.seal.(body) do
      response = %{status: status, headers: headers, body_ct: body_ct, body_key_id: body_key_id}

      case Store.idempotency_complete(
             request.endpoint,
             request.idempotency_key,
             request.fingerprint,
             response
           ) do
        :not_claimed -> {:error, Relay.Error.new(:accept_failed, "idempotency key not claimed")}
        stored -> {:ok, {stored, {status, headers, body}}}
      end
    end
  end

  defp outcome(changes) do
    {stored, response} = changes.stored

    %{
      notifications: changes.notifications,
      outbox: changes.outbox,
      response: response,
      stored: stored
    }
  end

  defp failed(step),
    do: Relay.Error.new(:accept_failed, "the accept transaction failed", %{step: step})

  defp uuid(binary) do
    {:ok, text} = Ecto.UUID.load(binary)
    text
  end
end
