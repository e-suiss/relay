defmodule Relay.Webhooks.Recovery do
  @moduledoc """
  The recovery operations of the delivery log (WH-31, WH-32, WH-33, WH-48): the resend and the cancellation of one message, and the four operations on an endpoint, `recover`, the filtered bulk `retry`, the `replay` of kept events and the cancellation of scheduled retries.

  An operation on an endpoint is started inside the request's transaction: its selection is counted, its audit record is written and its job is queued, all together. The work itself is done by `Relay.Webhooks.RecoveryWorker` in batches (`advance/1`): one batch of the selection in identifier order, then the next job, queued in the batch's transaction with the identifier it stopped at. The batches of a recover, a retry and a replay are spread over time by the endpoint's rate, so a wave of recovered messages stays within the endpoint's limits and in the tenant's fair share of the lane (WH-33 (2)); every recovered message keeps its event identifier (WH-33 (1)) and starts its schedule from the beginning (WH-32 (3)). A cancellation takes its first batch in the request, so the retries that were about to run are stopped at once. A selection ends at the time of the request unless it names an earlier end, so a message created later is never taken.

  Never selected by a recover or a retry: a test message, which is attempted once, and a message whose payload was over the hard limit and is not kept (WH-29). A replay takes the events of the endpoint's use and consumer that are still kept, of the given types or of the endpoint's subscription, for which the endpoint has no message yet.

  Every function runs inside the caller's scoped transaction.
  """

  alias Relay.Actor
  alias Relay.Webhooks.DeliveryLog
  alias Relay.Webhooks.EngineStore
  alias Relay.Webhooks.Fanout
  alias Relay.Webhooks.LogStore
  alias Relay.Webhooks.RecoveryWorker
  alias Relay.Webhooks.Settings

  @batch 100
  @operations ~w(recover retry replay cancel_retries)
  @actions %{
    "recover" => "webhook_endpoint.messages_recovered",
    "retry" => "webhook_endpoint.messages_retried",
    "replay" => "webhook_endpoint.events_replayed",
    "cancel_retries" => "webhook_endpoint.retries_cancelled"
  }

  @type id :: Relay.Id.t()

  @typedoc "A recovery operation on an endpoint as it is asked for: the `:operation`, the `:endpoint_id` and, when given, `:since`, `:until`, `:event_types`, `:states` and `:reasons`."
  @type request :: %{
          required(:operation) => String.t(),
          required(:endpoint_id) => id(),
          optional(:since) => DateTime.t() | nil,
          optional(:until) => DateTime.t() | nil,
          optional(:event_types) => [String.t()] | nil,
          optional(:states) => [String.t()] | nil,
          optional(:reasons) => [String.t()] | nil
        }

  @type refusal :: :not_found | :archived | :state_conflict | :in_flight | :unavailable

  @doc "How many messages or events one batch of a recovery operation takes."
  @spec batch() :: pos_integer()
  def batch, do: @batch

  # WH-31
  # WH-32 (1)
  # WH-32 (2)
  # WH-32 (4)
  # WH-48
  @doc "Queues one attempt of a message at once and writes its audit record; returns the message. A message whose attempt runs is `:in_flight`; an endpoint that is archived, paused or disabled takes no resend."
  @spec resend(id(), binary(), Actor.t()) :: {:ok, map()} | {:error, refusal()}
  def resend(message_id, digest, %Actor{} = actor) do
    with {:ok, message} <- found(LogStore.message(message_id)),
         :ok <- free(message, Relay.Clock.utc_now()),
         :ok <- deliverable(LogStore.endpoint(message["endpoint_id"])),
         :ok <- queued(Fanout.attempt_job(message_id, nil, true)) do
      :appended = audit("webhook_message.resent", "webhook_message", message_id, digest, actor)
      {:ok, message}
    end
  end

  # WH-31
  # WH-48
  @doc "Cancels the waiting attempts of one message and writes its audit record; returns the message. A message in a terminal state comes back unchanged; one whose attempt runs is `:in_flight`."
  @spec cancel(id(), binary(), Actor.t()) :: {:ok, map()} | {:error, refusal()}
  def cancel(message_id, digest, %Actor{} = actor) do
    case LogStore.message(message_id) do
      nil -> {:error, :not_found}
      %{"terminal_at" => %DateTime{}} = message -> {:ok, message}
      message -> cancelled(message, digest, actor)
    end
  end

  defp cancelled(%{"id" => id} = message, digest, actor) do
    with :ok <- free(message, Relay.Clock.utc_now()) do
      _count = Fanout.cancel([id], actor.ref)
      :appended = audit("webhook_message.cancelled", "webhook_message", id, digest, actor)
      {:ok, LogStore.message(id)}
    end
  end

  defp found(nil), do: {:error, :not_found}
  defp found(%{} = row), do: {:ok, row}

  # WH-32 (4)
  defp free(%{"state" => "in_flight"}, _now), do: {:error, :in_flight}

  defp free(%{"locked_until" => %DateTime{} = until}, now),
    do: if(DateTime.compare(until, now) == :gt, do: {:error, :in_flight}, else: :ok)

  defp free(_message, _now), do: :ok

  defp deliverable(%{"state" => "active"}), do: :ok
  defp deliverable(%{"state" => "archived"}), do: {:error, :archived}
  defp deliverable(_endpoint), do: {:error, :state_conflict}

  defp queued(:ok), do: :ok
  defp queued({:error, _reason}), do: {:error, :unavailable}

  # WH-31
  # WH-37
  # WH-48
  @doc "Starts a recovery operation on an endpoint: counts its selection, writes its audit record and queues its work. Returns how many messages, or for a replay events, it selected. An archived endpoint takes no operation, and a disabled one only the cancellation of its scheduled retries."
  @spec start(request(), binary(), Actor.t()) ::
          {:ok, non_neg_integer()} | {:error, refusal()}
  def start(%{operation: operation} = request, digest, %Actor{} = actor)
      when operation in @operations do
    now = Relay.Clock.utc_now()
    endpoint_id = request.endpoint_id

    with {:ok, endpoint} <- found(LogStore.endpoint(endpoint_id)),
         :ok <- startable(operation, endpoint["state"]) do
      selection = selection(request, now)
      selected = count(selection, endpoint)
      args = args(selection, actor.ref)
      action = Map.fetch!(@actions, operation)
      :appended = audit(action, "webhook_endpoint", endpoint_id, digest, actor)

      with :ok <- begun(operation, args, endpoint_id), do: {:ok, selected}
    end
  end

  defp startable(_operation, "archived"), do: {:error, :archived}
  defp startable("cancel_retries", _state), do: :ok
  defp startable(_operation, "disabled"), do: {:error, :state_conflict}
  defp startable(_operation, _state), do: :ok

  defp begun("cancel_retries", args, _endpoint_id) do
    case advance(args) do
      {:ok, _count} -> :ok
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp begun(_operation, args, endpoint_id), do: queued(job(args, endpoint_id, nil))

  # WH-30
  # WH-52
  defp selection(%{operation: operation} = request, now) do
    %{
      operation: operation,
      endpoint_id: request.endpoint_id,
      since: since(operation, Map.get(request, :since), now),
      until: earlier(Map.get(request, :until), now),
      event_types: Map.get(request, :event_types),
      states: Map.get(request, :states),
      reasons: Map.get(request, :reasons)
    }
  end

  defp since("replay", since, now), do: later(since, DeliveryLog.kept_since(:messages, now))
  defp since(_operation, since, _now), do: since

  defp later(nil, other), do: other
  defp later(at, other), do: if(DateTime.compare(at, other) == :gt, do: at, else: other)

  defp earlier(nil, other), do: other
  defp earlier(at, other), do: if(DateTime.compare(at, other) == :lt, do: at, else: other)

  defp count(%{operation: "replay"} = selection, endpoint),
    do: LogStore.replayed_count(selection, endpoint)

  defp count(selection, _endpoint), do: LogStore.selected_count(selection)

  # T-15
  defp args(selection, actor_ref) do
    %{
      "operation" => selection.operation,
      "endpoint_id" => Relay.Id.to_string(selection.endpoint_id),
      "since" => selection.since && DateTime.to_iso8601(selection.since),
      "until" => DateTime.to_iso8601(selection.until),
      "event_types" => selection.event_types,
      "states" => selection.states,
      "reasons" => selection.reasons,
      "actor_ref" => actor_ref,
      "cursor" => nil
    }
  end

  defp job(args, endpoint_id, at) do
    scope = Relay.Scope.to_job_args(EngineStore.current_scope())

    Settings.runtime().enqueue(%{
      worker: RecoveryWorker,
      args: Map.merge(args, scope),
      ref_id: endpoint_id,
      scheduled_at: at
    })
  end

  # WH-31
  # WH-32 (3)
  # WH-33
  @doc "Does one batch of a recovery operation from the job arguments `start/3` made, and queues the next batch while the selection has more. Returns how many messages the batch restarted, created or cancelled; an operation whose endpoint is gone, archived or, unless it cancels, disabled ends without doing anything."
  @spec advance(map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def advance(%{"operation" => operation} = args) when operation in @operations do
    with {:ok, selection, cursor} <- decoded(args),
         %{"state" => state} = endpoint <- LogStore.endpoint(selection.endpoint_id),
         :ok <- startable(operation, state) do
      ids = taken(selection, endpoint, cursor)
      count = applied(selection, ids, args["actor_ref"])

      with :ok <- continued(args, endpoint, ids), do: {:ok, count}
    else
      {:error, :invalid_args} -> {:error, :invalid_args}
      _ended -> {:ok, 0}
    end
  end

  defp decoded(args) do
    with {:ok, endpoint_id} <- Relay.Id.parse(args["endpoint_id"]),
         {:ok, since} <- time(args["since"]),
         {:ok, %DateTime{} = until} <- time(args["until"]),
         {:ok, cursor} <- cursor(args["cursor"]) do
      selection = %{
        operation: args["operation"],
        endpoint_id: endpoint_id,
        since: since,
        until: until,
        event_types: args["event_types"],
        states: args["states"],
        reasons: args["reasons"]
      }

      {:ok, selection, cursor}
    else
      _invalid -> {:error, :invalid_args}
    end
  end

  defp time(nil), do: {:ok, nil}

  defp time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  defp time(_other), do: :error

  defp cursor(nil), do: {:ok, nil}
  defp cursor(text), do: Relay.Id.parse(text)

  defp taken(%{operation: "replay"} = selection, endpoint, cursor),
    do: LogStore.replayed(selection, endpoint, cursor, @batch)

  defp taken(selection, _endpoint, cursor), do: LogStore.selected(selection, cursor, @batch)

  defp applied(_selection, [], _actor_ref), do: 0

  defp applied(%{operation: "replay", endpoint_id: endpoint_id}, ids, _actor_ref),
    do: Enum.count(ids, &(Fanout.replay(&1, endpoint_id) != nil))

  defp applied(%{operation: "cancel_retries"}, ids, actor_ref), do: Fanout.cancel(ids, actor_ref)
  defp applied(_selection, ids, _actor_ref), do: Fanout.restart(ids)

  # WH-33 (2)
  defp continued(args, endpoint, ids) when length(ids) == @batch do
    next = Map.put(args, "cursor", Relay.Id.to_string(List.last(ids)))
    job(next, endpoint["id"], pace(args["operation"], endpoint))
  end

  defp continued(_args, _endpoint, _ids), do: :ok

  defp pace("cancel_retries", _endpoint), do: nil

  defp pace(_operation, endpoint) do
    rate = endpoint["rate_per_second"] || Settings.isolation().rate
    DateTime.add(Relay.Clock.utc_now(), div(@batch * 1000, rate) + 1000, :millisecond)
  end

  defp audit(action, target_type, target_id, digest, actor),
    do: LogStore.audit(action, target_type, target_id, nil, digest, actor)
end
