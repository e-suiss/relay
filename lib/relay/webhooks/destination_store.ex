defmodule Relay.Webhooks.DestinationStore do
  @moduledoc """
  Data access of the events a tenant delivers to its consumers (use `destination`, WH-1) and of the event feed of the development tunnel. A tenant event is written only through `relay_fn.webhook_destination_event_record`, with its payload sealed, and is never deleted. Every function runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  @type id :: Relay.Id.t()

  @recorded ~w(recorded exists)a
  @types "relay.webhook_event_types t JOIN relay.webhook_event_type_versions v ON v.tenant_id = t.tenant_id AND v.environment = t.environment AND v.event_type_id = t.id"
  @event_columns "e.id, e.use_kind, e.event_type, e.schema_version, e.origin, e.source, e.subject, e.seq, e.occurred_at, e.traceparent, e.payload, e.payload_erased_at, e.created_at"

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # WH-2
  @doc "Reads the consumer with `key`: its identifier, state and event source; or `nil`."
  @spec consumer(String.t()) :: map() | nil
  def consumer(key) do
    one("SELECT c.id, c.state, c.source FROM relay.webhook_consumers c WHERE c.key = $1", [key])
  end

  # WH-13
  # WH-14
  @doc "Reads the tenant event type named `name` with the current version of its schema, or `nil`."
  @spec event_type(String.t()) :: map() | nil
  def event_type(name) do
    one(
      """
      SELECT t.id, t.state, v.version, v.json_schema, v.identifiers FROM #{@types}
        AND v.version = t.current_version
      WHERE t.name = $1
      """,
      [name]
    )
  end

  # WH-13
  @doc "The identifier fields of one schema version of the tenant event type named `name`; empty when it is unknown."
  @spec identifiers(String.t(), pos_integer()) :: [String.t()]
  def identifiers(name, version) do
    sql = "SELECT v.identifiers FROM #{@types} WHERE t.name = $1 AND v.version = $2"

    case one(sql, [name, version]) do
      %{"identifiers" => identifiers} -> identifiers
      nil -> []
    end
  end

  # WH-16
  @doc "The endpoints of a consumer that are not archived and subscribe to `event_type` or to `*`, with their retry schedule."
  @spec subscribers(id(), String.t()) :: [map()]
  def subscribers(consumer_id, event_type) do
    all(
      """
      SELECT e.id, e.state, e.retry_schedule FROM relay.webhook_endpoints e
      WHERE e.use_kind = 'destination' AND e.consumer_id = $1 AND e.state <> 'archived'
        AND (e.event_types @> ARRAY[$2::text] OR e.event_types @> ARRAY['*'::text])
      ORDER BY e.id
      """,
      [consumer_id, event_type]
    )
  end

  # WH-1
  # WH-13
  @doc "Records a tenant event with its sealed payload; an event that exists is left as it is."
  @spec record(id(), map(), DateTime.t()) :: :recorded | :exists
  def record(event_id, event, %DateTime{} = now) do
    [row] =
      Repo.call!("relay_fn.webhook_destination_event_record", [
        event_id,
        event.consumer_id,
        event.event_type,
        event.schema_version,
        event.source,
        event.occurred_at,
        event.traceparent,
        event.payload_ct,
        event.payload_key_id,
        event.payload_digest,
        now
      ])

    Repo.code!(row["webhook_destination_event_record"], @recorded)
  end

  # WH-13
  @doc "The sealed payload of an event: its ciphertext and the tenant key that opens it; `nil` when the event is unknown or its payload was erased."
  @spec sealed_payload(id()) :: %{ct: binary(), key_id: id()} | nil
  def sealed_payload(event_id) do
    sql = "SELECT e.payload_ct, e.payload_key_id FROM relay.webhook_events e WHERE e.id = $1"

    case one(sql, [event_id]) do
      %{"payload_ct" => <<_::8, _rest::binary>> = ct, "payload_key_id" => <<_::128>> = key_id} ->
        %{ct: ct, key_id: key_id}

      _none ->
        nil
    end
  end

  # WF-11
  @doc "The states of the messages of events, by event identifier."
  @spec states([id()]) :: %{id() => [String.t()]}
  def states([]), do: %{}

  def states(event_ids) do
    "SELECT m.event_id, m.state FROM relay.webhook_messages m WHERE m.event_id = ANY ($1)"
    |> all([event_ids])
    |> Enum.group_by(& &1["event_id"], & &1["state"])
  end

  # WH-45 (2)
  # API-56
  @doc "A page of Relay's own events of the scope, newest first, optionally of one type and created at or after `since`, without the types named in `excluded`; at most `limit + 1` rows."
  @spec events(String.t() | nil, DateTime.t() | nil, [String.t()], map() | nil, pos_integer()) ::
          [map()]
  def events(event_type, since, excluded, cursor, limit) do
    {condition, order, params} = position(cursor, [event_type, since, excluded])

    sql = """
    SELECT #{@event_columns}, e.created_at AS cursor_at FROM relay.webhook_events e
    WHERE e.use_kind = 'relay_events' AND e.origin = 'outbox'
      AND ($1::text IS NULL OR e.event_type = $1)
      AND ($2::timestamptz IS NULL OR e.created_at >= $2)
      AND NOT (e.event_type = ANY($3::text[]))#{condition}
    ORDER BY e.created_at #{order}, e.id #{order}
    LIMIT #{limit + 1}
    """

    rows = all(sql, params)
    if order == "ASC", do: Enum.reverse(rows), else: rows
  end

  defp position(nil, params), do: {"", "DESC", params}

  defp position(%{direction: :after, sort_ts_us: ts, id: id}, params),
    do: {" AND (e.created_at, e.id) < ($4, $5)", "DESC", params ++ [from_us(ts), id]}

  defp position(%{direction: :before, sort_ts_us: ts, id: id}, params),
    do: {" AND (e.created_at, e.id) > ($4, $5)", "ASC", params ++ [from_us(ts), id]}

  defp from_us(us), do: DateTime.from_unix!(us, :microsecond)

  defp one(sql, params) do
    case all(sql, params) do
      [row] -> row
      [] -> nil
    end
  end

  defp all(sql, params) do
    %{rows: rows, columns: columns} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
