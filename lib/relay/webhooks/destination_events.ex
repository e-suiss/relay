defmodule Relay.Webhooks.DestinationEvents do
  @moduledoc """
  The events a tenant delivers to its consumers through the `webhook` step of a workflow (use `destination`, WH-1, WH-13, WF-11). Such an event goes through the engine of Relay's own events: one message for each endpoint of the consumer that subscribes to its type, with the same signing, schedule, terminal states and delivery log.

  `prepare/4` runs outside any transaction: it finds the consumer and the tenant event type, validates the event data against the current version of the type's schema and seals the data under the tenant's data key, because a tenant's data may be personal. `emit/3` runs inside the caller's scoped transaction: it records the event with its sealed payload and creates the messages and their jobs. An event identifier that was emitted before creates nothing, so the runs of one accepted event deliver one event.

  The body of an attempt is built by `payload/3`: the identifiers the type's schema version declares and, of the other fields, exactly those the endpoint version the message is pinned to allow-lists. Nothing else leaves, and no tenant code runs (WH-13 (2)). The answer of the consumer is kept in the attempt log only; `states/1` gives a workflow the states of an event's messages and nothing of the answers (WF-11).
  """

  alias Relay.Scope
  alias Relay.Webhooks.DestinationStore
  alias Relay.Webhooks.EngineStore
  alias Relay.Webhooks.Envelope
  alias Relay.Webhooks.Fanout
  alias Relay.Webhooks.RetrySchedule
  alias Relay.Webhooks.Settings

  @dialect "https://json-schema.org/draft/2020-12/schema"
  @field {"webhook_events", "payload_ct"}

  @typedoc "An event that is ready to be emitted: its consumer, type and schema version, the `source` its envelope carries, its sealed data and, when it is over the hard limit, the reason its messages are dead-lettered with."
  @type prepared :: %{
          consumer_id: Relay.Id.t(),
          event_type: String.t(),
          schema_version: pos_integer(),
          source: String.t(),
          payload_ct: binary(),
          payload_key_id: Relay.Id.t(),
          payload_digest: <<_::256>>,
          reason: String.t() | nil
        }

  @type refusal ::
          :consumer_not_found
          | :consumer_archived
          | :event_type_not_found
          | :event_type_archived
          | :payload_invalid

  # WH-13 (1)
  # WH-8 (4)
  # WH-29
  @doc "Prepares an event of the tenant event type `event_type` for the consumer with `consumer_key`, outside any transaction. A refusal is a decision about the event; an error means the data could not be read or sealed now."
  @spec prepare(Scope.t(), String.t(), String.t(), term()) ::
          {:ok, prepared()} | {:refused, refusal()} | {:error, term()}
  def prepare(%Scope{} = scope, consumer_key, event_type, data)
      when is_binary(consumer_key) and is_binary(event_type) do
    read = fn _status ->
      {DestinationStore.consumer(consumer_key), DestinationStore.event_type(event_type)}
    end

    with {:ok, {consumer, type}} <- DestinationStore.in_scope(scope, read),
         :ok <- target(consumer, type),
         :ok <- valid(type["json_schema"], data) do
      sealed(scope, consumer, event_type, type, data)
    end
  end

  defp target(nil, _type), do: {:refused, :consumer_not_found}
  defp target(%{"state" => "archived"}, _type), do: {:refused, :consumer_archived}
  defp target(_consumer, nil), do: {:refused, :event_type_not_found}
  defp target(_consumer, %{"state" => "archived"}), do: {:refused, :event_type_archived}
  defp target(_consumer, _type), do: :ok

  defp valid(schema, %{} = data) when not is_struct(data) do
    with {:ok, root} <- JSV.build(schema, default_meta: @dialect),
         {:ok, _data} <- JSV.validate(data, root, cast: false) do
      :ok
    else
      _invalid -> {:refused, :payload_invalid}
    end
  end

  defp valid(_schema, _data), do: {:refused, :payload_invalid}

  defp sealed(scope, consumer, event_type, type, data) do
    encoded = Jason.encode!(data)
    too_large? = byte_size(encoded) > Settings.payload_max()
    stored = if too_large?, do: "{}", else: encoded

    with {:ok, %{ct: ct, key_id: key_id}} <-
           Settings.sealer().seal(scope, @field, Relay.Redacted.wrap(stored)) do
      {:ok,
       %{
         consumer_id: consumer["id"],
         event_type: event_type,
         schema_version: type["version"],
         source: consumer["source"] || Settings.source(),
         payload_ct: ct,
         payload_key_id: key_id,
         payload_digest: :crypto.hash(:sha256, encoded),
         reason: if(too_large?, do: "payload_too_large")
       }}
    end
  end

  # WH-1
  # WH-2
  # WH-16
  # INV-12
  @doc "Records a prepared event under `event_id` and creates its messages with their jobs, inside the caller's scoped transaction. `opts` may carry `:occurred_at` and `:traceparent`. Returns how many messages were created; an event that was emitted before creates none."
  @spec emit(Relay.Id.t(), prepared(), map()) :: %{messages: non_neg_integer()}
  def emit(<<_::128>> = event_id, %{consumer_id: consumer_id} = prepared, opts) do
    now = Relay.Clock.utc_now()

    event =
      Map.merge(prepared, %{
        occurred_at: Map.get(opts, :occurred_at) || now,
        traceparent: Map.get(opts, :traceparent)
      })

    _recorded = DestinationStore.record(event_id, event, now)

    planned =
      for endpoint <- DestinationStore.subscribers(consumer_id, prepared.event_type),
          do: planned(endpoint, now)

    options = %{origin: "event", reason: prepared.reason}
    created = EngineStore.fan_out(event_id, nil, nil, nil, planned, options, now)
    times = Map.new(planned, &{&1.id, &1.next_attempt_at})

    for %{"state" => "pending", "message_id" => id} <- created do
      :ok = Fanout.attempt_job(id, Map.fetch!(times, id))
    end

    %{messages: length(created)}
  end

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

  # WF-11
  @doc "The states of the messages of events, by event identifier, inside the caller's scoped transaction. An event without a message is absent."
  @spec states([Relay.Id.t()]) :: %{Relay.Id.t() => [String.t()]}
  defdelegate states(event_ids), to: DestinationStore

  # WH-13
  # WH-12
  @doc "The data an attempt delivers for a stored tenant event, outside any transaction: the identifiers of its schema version and the fields of `allow_list`. `:erased` when the payload's retention ended, `:unavailable` when it cannot be read or opened now."
  @spec payload(Scope.t(), map(), [String.t()] | nil) ::
          {:ok, map()} | {:error, :erased | :unavailable}
  def payload(%Scope{} = scope, %{"id" => id, "event_type" => type} = event, allow_list) do
    read = fn _status ->
      {DestinationStore.sealed_payload(id),
       DestinationStore.identifiers(type, event["schema_version"])}
    end

    case DestinationStore.in_scope(scope, read) do
      {:ok, {nil, _identifiers}} -> {:error, :erased}
      {:ok, {sealed, identifiers}} -> opened(scope, sealed, identifiers, allow_list || [])
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp opened(scope, %{ct: ct, key_id: key_id}, identifiers, allow_list) do
    with {:ok, opened} <- Settings.sealer().open(scope, @field, key_id, ct),
         {:ok, %{} = data} <- Jason.decode(Relay.Redacted.expose(opened)) do
      {:ok, data |> Envelope.thin(identifiers) |> Envelope.snapshot(data, allow_list)}
    else
      _unreadable -> {:error, :unavailable}
    end
  end
end
