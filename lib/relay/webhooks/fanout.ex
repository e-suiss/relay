defmodule Relay.Webhooks.Fanout do
  @moduledoc """
  How events become messages (WH-2, INV-12). An event is recorded once and gets one message for each endpoint that subscribes to its type; the database keeps `(endpoint, event)` unique, so dispatching an event again creates nothing. A message for an endpoint that is paused, disabled or behind an open circuit breaker is created `held` with its reason and is never dropped (WH-37); a payload over the hard limit is recorded and its messages are `dead_lettered` with `payload_too_large` (WH-29). The job of every message that can be attempted is queued in the same transaction as the message.

  Every function runs inside the caller's scoped transaction.
  """

  alias Relay.Webhooks.AttemptWorker
  alias Relay.Webhooks.EngineStore
  alias Relay.Webhooks.Envelope
  alias Relay.Webhooks.ReleaseWorker
  alias Relay.Webhooks.RetrySchedule
  alias Relay.Webhooks.Settings

  @disabled "webhook_endpoint.disabled"
  @tested "webhook_endpoint.tested"

  @typedoc "One of Relay's own events as the outbox handed it over: its identifier and type, its data with external identifiers, its stream as subject with epoch and sequence number, when it happened and its trace context."
  @type event :: %{
          required(:id) => Relay.Id.t(),
          required(:type) => String.t(),
          required(:data) => map(),
          required(:subject) => String.t(),
          required(:epoch) => pos_integer(),
          required(:seq) => pos_integer(),
          required(:occurred_at) => DateTime.t(),
          optional(:traceparent) => String.t() | nil
        }

  # WH-1
  # WH-2
  # WH-11
  # WH-16
  # WH-29
  # WH-34 (2)
  # WH-37
  # INV-12
  @doc "Records one of Relay's own events and creates its messages; returns the created messages with their state. Only an event type of the catalog is delivered (WH-53), and of its data only the identifiers the catalog declares for the thin payload are kept (WH-11)."
  @spec relay_event(event()) :: [map()]
  def relay_event(%{type: type, data: data} = event) do
    with {:ok, identifiers} <- Relay.EventCatalog.identifiers(type),
         {:ok, %{version: version}} <- Relay.EventCatalog.fetch(type) do
      recorded(event, Envelope.thin(data, identifiers), version)
    else
      :error -> []
    end
  end

  defp recorded(%{id: id, type: type} = event, data, version) do
    now = Relay.Clock.utc_now()
    encoded = Jason.encode!(data)
    too_large? = byte_size(encoded) > Settings.payload_max()

    row = %{
      "use_kind" => "relay_events",
      "event_type" => type,
      "schema_version" => version,
      "origin" => "outbox",
      "source" => Settings.source(),
      "subject" => event.subject,
      "stream_epoch" => event.epoch,
      "seq" => event.seq,
      "occurred_at" => event.occurred_at,
      "traceparent" => Map.get(event, :traceparent)
    }

    messages =
      for endpoint <- EngineStore.subscribers(type), not own_disable?(endpoint, type, data) do
        planned(endpoint, now)
      end

    payload = if too_large?, do: %{}, else: data
    opts = %{origin: "event", reason: if(too_large?, do: "payload_too_large")}
    digest = :crypto.hash(:sha256, encoded)

    id
    |> EngineStore.fan_out(row, payload, digest, messages, opts, now)
    |> queued(messages)
  end

  # WH-34 (2)
  defp own_disable?(%{"id" => id}, @disabled, %{"endpoint_id" => endpoint_id}),
    do: Relay.ExternalId.encode("whe", id) == endpoint_id

  defp own_disable?(_endpoint, _type, _data), do: false

  # WH-45 (3)
  @doc "Creates the test event of an endpoint and its one message, which is attempted once; returns the message's identifier, or `nil` when the endpoint is archived."
  @spec test_event(map()) :: Relay.Id.t() | nil
  def test_event(%{"id" => endpoint_id} = endpoint) do
    now = Relay.Clock.utc_now()

    data = %{
      "endpoint_id" => Relay.ExternalId.encode("whe", endpoint_id),
      "requested_at" => DateTime.to_iso8601(now)
    }

    row = %{
      "use_kind" => endpoint["use_kind"],
      "event_type" => @tested,
      "schema_version" => 1,
      "origin" => "test",
      "source" => Settings.source(),
      "subject" => "webhook_endpoint:" <> Relay.Id.to_string(endpoint_id),
      "occurred_at" => now
    }

    message = planned(%{"id" => endpoint_id, "retry_schedule" => [0]}, now)
    digest = :crypto.hash(:sha256, Jason.encode!(data))
    opts = %{origin: "test"}

    Relay.Id.generate()
    |> EngineStore.fan_out(row, data, digest, [message], opts, now)
    |> queued([message])
    |> created_id()
  end

  # WH-31
  # WH-33 (1)
  @doc "Creates the message of an existing event for another endpoint: a replay, which keeps the event's identifier. Returns the message's identifier, or `nil` when the endpoint already has a message for the event or either is unknown."
  @spec replay(Relay.Id.t(), Relay.Id.t()) :: Relay.Id.t() | nil
  def replay(event_id, endpoint_id) do
    now = Relay.Clock.utc_now()

    case EngineStore.endpoint(endpoint_id) do
      nil ->
        nil

      endpoint ->
        message = planned(endpoint, now)

        event_id
        |> EngineStore.fan_out(nil, nil, nil, [message], %{origin: "replay"}, now)
        |> queued([message])
        |> created_id()
    end
  end

  defp created_id([%{"message_id" => id}]), do: id
  defp created_id([]), do: nil

  defp planned(%{"id" => endpoint_id} = endpoint, now) do
    id = Relay.Id.generate()
    schedule = Settings.schedule(endpoint)
    {:ok, at} = RetrySchedule.next_attempt_at(schedule, 0, id, now, Settings.jitter_bp())

    %{
      id: id,
      endpoint_id: endpoint_id,
      next_attempt_at: at,
      window_ends_at: Settings.window_ends_at(schedule, now)
    }
  end

  defp queued(created, planned) do
    times = Map.new(planned, &{&1.id, &1.next_attempt_at})

    for %{"state" => "pending", "message_id" => id} <- created do
      :ok = attempt_job(id, Map.fetch!(times, id))
    end

    created
  end

  # T-15
  @doc "Queues the attempt job of a message for `at`; `manual` makes it a resend (WH-32)."
  @spec attempt_job(Relay.Id.t(), DateTime.t() | nil, boolean()) :: :ok | {:error, term()}
  def attempt_job(message_id, at, manual \\ false) do
    args =
      EngineStore.current_scope()
      |> Relay.Scope.to_job_args()
      |> Map.put("message_id", Relay.Id.to_string(message_id))

    args = if manual, do: Map.put(args, "manual", true), else: args

    Settings.runtime().enqueue(%{
      worker: AttemptWorker,
      args: args,
      ref_id: message_id,
      scheduled_at: at
    })
  end

  # T-15
  @doc "Queues the release of an endpoint's messages held for `hold_reason` at `at`."
  @spec release_job(Relay.Id.t(), String.t(), DateTime.t() | nil) :: :ok | {:error, term()}
  def release_job(endpoint_id, hold_reason, at) do
    args =
      EngineStore.current_scope()
      |> Relay.Scope.to_job_args()
      |> Map.merge(%{
        "endpoint_id" => Relay.Id.to_string(endpoint_id),
        "hold_reason" => hold_reason
      })

    Settings.runtime().enqueue(%{
      worker: ReleaseWorker,
      args: args,
      ref_id: endpoint_id,
      scheduled_at: at
    })
  end

  # WH-31
  # WH-33 (2)
  # WH-35 (2)
  @doc """
  Releases held messages of an endpoint at a controlled rate: at most `batch` of them, spread over time by the endpoint's rate, and queues itself again while more remain. Messages held for a pause are released once the endpoint is active again; of the messages behind the circuit breaker one is released as the probe while the breaker is not closed, and the release waits while the breaker's open time runs. Returns how many messages were released.
  """
  @spec release(Relay.Id.t(), String.t(), pos_integer()) :: non_neg_integer()
  def release(endpoint_id, hold_reason, batch) do
    now = Relay.Clock.utc_now()

    case allowance(EngineStore.endpoint(endpoint_id), hold_reason, batch, now) do
      {:later, at} ->
        :ok = release_job(endpoint_id, hold_reason, at)
        0

      0 ->
        0

      limit ->
        released(endpoint_id, hold_reason, limit, batch, now)
    end
  end

  defp allowance(nil, _hold_reason, _batch, _now), do: 0
  defp allowance(%{"state" => state}, _hold_reason, _batch, _now) when state != "active", do: 0

  defp allowance(%{"id" => id}, "breaker_open", batch, now) do
    case EngineStore.health(id) do
      %{"breaker_state" => "closed"} -> batch
      %{"breaker_state" => "open", "breaker_retry_at" => at} -> probe_or_later(at, now)
      _half_open -> 1
    end
  end

  defp allowance(_endpoint, _hold_reason, batch, _now), do: batch

  defp probe_or_later(at, now),
    do: if(DateTime.compare(at, now) == :gt, do: {:later, at}, else: 1)

  defp released(endpoint_id, hold_reason, limit, batch, now) do
    rate = EngineStore.endpoint(endpoint_id)["rate_per_second"] || Settings.isolation().rate
    held = EngineStore.held(endpoint_id, hold_reason, limit)

    entries =
      for {%{"id" => id}, index} <- Enum.with_index(held) do
        %{id: id, next_attempt_at: DateTime.add(now, div(index * 1000, rate), :millisecond)}
      end

    times = Map.new(entries, &{&1.id, &1.next_attempt_at})

    count =
      entries
      |> EngineStore.requeue("release", now)
      |> Enum.count(fn %{"message_id" => id} -> attempt_job(id, Map.fetch!(times, id)) == :ok end)

    if length(held) == batch do
      again = DateTime.add(now, div(batch * 1000, rate) + 1000, :millisecond)
      :ok = release_job(endpoint_id, hold_reason, again)
    end

    count
  end

  # WH-32 (3)
  @doc "Starts the schedule of messages from the beginning (recover, bulk retry): every message that is not delivered and not being attempted is queued again with a new schedule and the same event identifier. Returns how many were restarted."
  @spec restart([Relay.Id.t()]) :: non_neg_integer()
  def restart(message_ids) do
    now = Relay.Clock.utc_now()

    entries =
      for id <- message_ids, message = EngineStore.message(id), message != nil do
        endpoint = EngineStore.endpoint(message["endpoint_id"])
        schedule = Settings.schedule(endpoint)
        {:ok, at} = RetrySchedule.next_attempt_at(schedule, 0, id, now, Settings.jitter_bp())
        %{id: id, next_attempt_at: at, window_ends_at: Settings.window_ends_at(schedule, now)}
      end

    times = Map.new(entries, &{&1.id, &1.next_attempt_at})

    entries
    |> EngineStore.requeue("restart", now)
    |> Enum.count(fn %{"message_id" => id} -> attempt_job(id, Map.fetch!(times, id)) == :ok end)
  end

  # WH-31
  @doc "Cancels the scheduled attempts of messages: every message that is not terminal and not being attempted becomes `cancelled`. Returns how many were cancelled."
  @spec cancel([Relay.Id.t()], String.t()) :: non_neg_integer()
  def cancel(message_ids, actor_ref) do
    now = Relay.Clock.utc_now()
    cancelled = EngineStore.terminate(message_ids, "cancelled", "cancelled", actor_ref, now)
    Enum.each(cancelled, &Settings.runtime().cancel(&1["message_id"]))
    length(cancelled)
  end
end
