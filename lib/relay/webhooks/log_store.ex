defmodule Relay.Webhooks.LogStore do
  @moduledoc """
  Reads of the delivery log (WH-10, WH-30) and the selections of the recovery operations (WH-31): pages of messages and of the events an endpoint missed, the attempts of a message, and the messages or events a recover, a bulk retry, a replay or a cancellation of scheduled retries acts on. A message row carries, under `"webhook_id"`, the identifier its consumer deduplicates by (WH-33). Messages are paged by their identifier, which is a UUIDv7, so the newest come first. Every function runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo
  alias Relay.Webhooks.Engine

  @type id :: Relay.Id.t()
  @type cursor :: map() | nil

  @typedoc "What a recovery operation selects: its `:operation` (`recover`, `retry`, `replay` or `cancel_retries`), the `:endpoint_id`, the creation time range from `:since` (or `nil`) to before `:until`, and the `:event_types`, `:states` and `:reasons` filters, each `nil` when not given."
  @type selection :: %{
          operation: String.t(),
          endpoint_id: id(),
          since: DateTime.t() | nil,
          until: DateTime.t(),
          event_types: [String.t()] | nil,
          states: [String.t()] | nil,
          reasons: [String.t()] | nil
        }

  @failed ~w(failed_permanent exhausted expired window_exceeded dead_lettered cancelled)
  @waiting ~w(pending scheduled held)

  @message_columns "m.id, m.endpoint_id, m.event_id, m.endpoint_version, m.event_type, m.origin, m.state, m.hold_reason, m.reason, m.total_attempt_count, m.next_attempt_at, m.locked_until, m.last_attempt_at, m.last_response_status, m.delivered_at, m.terminal_at, m.expires_at, m.created_at, m.updated_at, ev.origin AS event_origin"
  @messages "relay.webhook_messages m JOIN relay.webhook_events ev ON ev.tenant_id = m.tenant_id AND ev.environment = m.environment AND ev.id = m.event_id"
  @attempt_columns "a.id, a.message_id, a.endpoint_id, a.attempt_no, a.trigger_kind, a.result, a.failure_code, a.response_status, a.duration_ms, a.webhook_timestamp, a.body_digest, a.signature, host(a.destination_ip) AS destination_ip, a.retry_after_seconds, a.started_at, a.finished_at, a.created_at"
  @answer_columns "a.response_ct, a.response_key_id, a.response_truncated, a.response_erased_at"
  @selected """
  m.endpoint_id = $1 AND ($2::timestamptz IS NULL OR m.created_at >= $2) AND m.created_at < $3
    AND ($4::text[] IS NULL OR m.event_type = ANY ($4::text[]))
    AND (m.state = ANY ($5::text[]) OR ($6::boolean AND m.hold_reason = 'endpoint_disabled'))
    AND ($7::text[] IS NULL OR m.reason = ANY ($7::text[]))
    AND ($8::boolean OR (m.origin <> 'test' AND m.reason IS DISTINCT FROM 'payload_too_large'))
  """
  @replayed """
  e.use_kind = $1 AND e.consumer_id IS NOT DISTINCT FROM $2::uuid AND e.origin <> 'test'
    AND e.payload_erased_at IS NULL AND e.created_at >= $3 AND e.created_at < $4
    AND ($5::text[] @> ARRAY['*'::text] OR e.event_type = ANY ($5::text[]))
    AND NOT EXISTS (SELECT 1 FROM relay.webhook_messages m
      WHERE m.tenant_id = e.tenant_id AND m.environment = e.environment AND m.event_id = e.id
        AND (m.endpoint_id = $6 OR m.reason = 'payload_too_large'))
  """

  # WH-27
  @doc "The terminal states other than `delivered`: the states of the dead letter queue."
  @spec failed_states() :: [String.t(), ...]
  def failed_states, do: @failed

  # WH-2
  # WH-33 (1)
  @doc "Reads a message with its `\"webhook_id\"`, or `nil`."
  @spec message(id()) :: map() | nil
  def message(id) do
    "SELECT #{@message_columns} FROM #{@messages} WHERE m.id = $1"
    |> all([id])
    |> Enum.map(&identified/1)
    |> List.first()
  end

  # WH-30 (3)
  # API-56
  @doc "A page of messages, newest first, at most `limit + 1`. `filters` may hold `:endpoint_id`, `:event_id`, `:state`, `:event_type`, `:created_after` and `:created_before`; with `missed: true` only the messages an endpoint missed come back (WH-30 (2)): those in a terminal state other than `delivered` and those held because the endpoint was disabled."
  @spec messages(map(), cursor(), pos_integer()) :: [map()]
  def messages(filters, cursor, limit) do
    where = """
    ($1::uuid IS NULL OR m.endpoint_id = $1) AND ($2::uuid IS NULL OR m.event_id = $2)
      AND ($3::text IS NULL OR m.state = $3) AND ($4::text IS NULL OR m.event_type = $4)
      AND ($5::timestamptz IS NULL OR m.created_at >= $5)
      AND ($6::timestamptz IS NULL OR m.created_at < $6)
      AND (NOT $7::boolean OR m.state = ANY ($8::text[]) OR m.hold_reason = 'endpoint_disabled')
    """

    params = [
      filters[:endpoint_id],
      filters[:event_id],
      filters[:state],
      filters[:event_type],
      filters[:created_after],
      filters[:created_before],
      filters[:missed] == true,
      @failed
    ]

    {condition, order, params} = keyset("m.id", cursor, params, :newest_first)

    sql = """
    SELECT #{@message_columns} FROM #{@messages}
    WHERE #{where}#{condition}
    ORDER BY m.id #{order}
    LIMIT #{limit + 1}
    """

    sql |> all(params) |> ordered(order, "DESC") |> Enum.map(&identified/1)
  end

  defp identified(%{"event_origin" => origin, "event_id" => event_id} = row),
    do: Map.put(row, "webhook_id", Engine.webhook_id(%{"origin" => origin, "id" => event_id}))

  # WH-10
  # API-56
  @doc "A page of the attempts of a message in attempt order, without their answers; at most `limit + 1`."
  @spec attempts(id(), cursor(), pos_integer()) :: [map()]
  def attempts(message_id, cursor, limit) do
    {condition, order, params} = keyset("a.attempt_no", cursor, [message_id], :oldest_first)

    sql = """
    SELECT #{@attempt_columns} FROM relay.webhook_attempts a
    WHERE a.message_id = $1#{condition}
    ORDER BY a.attempt_no #{order}
    LIMIT #{limit + 1}
    """

    sql |> all(params) |> ordered(order, "ASC")
  end

  # WH-10
  @doc "Reads one attempt of a message with its sealed answer, or `nil`."
  @spec attempt(id(), id()) :: map() | nil
  def attempt(message_id, attempt_id) do
    sql = """
    SELECT #{@attempt_columns}, #{@answer_columns} FROM relay.webhook_attempts a
    WHERE a.message_id = $1 AND a.id = $2
    """

    sql |> all([message_id, attempt_id]) |> List.first()
  end

  defp keyset(_column, nil, params, :newest_first), do: {"", "DESC", params}
  defp keyset(_column, nil, params, :oldest_first), do: {"", "ASC", params}

  defp keyset(column, %{direction: direction} = cursor, params, sort) do
    n = length(params) + 1
    value = if sort == :newest_first, do: cursor.id, else: cursor.sort_ts_us

    case {direction, sort} do
      {:after, :newest_first} -> {" AND #{column} < $#{n}", "DESC", params ++ [value]}
      {:before, :newest_first} -> {" AND #{column} > $#{n}", "ASC", params ++ [value]}
      {:after, :oldest_first} -> {" AND #{column} > $#{n}", "ASC", params ++ [value]}
      {:before, :oldest_first} -> {" AND #{column} < $#{n}", "DESC", params ++ [value]}
    end
  end

  defp ordered(rows, order, order), do: rows
  defp ordered(rows, _order, _wanted), do: Enum.reverse(rows)

  # WH-31
  @doc "Reads what a recovery operation needs of an endpoint: its use, consumer, state, subscription and rate; or `nil`."
  @spec endpoint(id()) :: map() | nil
  def endpoint(id) do
    sql = """
    SELECT e.id, e.use_kind, e.consumer_id, e.state, e.event_types, e.rate_per_second
    FROM relay.webhook_endpoints e WHERE e.id = $1
    """

    sql |> all([id]) |> List.first()
  end

  # WH-31
  @doc "How many messages a `recover`, `retry` or `cancel_retries` selection holds."
  @spec selected_count(selection()) :: non_neg_integer()
  def selected_count(selection) do
    sql = "SELECT count(*) AS count FROM relay.webhook_messages m WHERE #{@selected}"
    [%{"count" => count}] = all(sql, selected_params(selection))
    count
  end

  # WH-31
  @doc "The identifiers of at most `limit` messages of a `recover`, `retry` or `cancel_retries` selection after `cursor`, in identifier order."
  @spec selected(selection(), id() | nil, pos_integer()) :: [id()]
  def selected(selection, cursor, limit) do
    sql = """
    SELECT m.id FROM relay.webhook_messages m
    WHERE #{@selected} AND ($9::uuid IS NULL OR m.id > $9)
    ORDER BY m.id LIMIT $10
    """

    for %{"id" => id} <- all(sql, selected_params(selection) ++ [cursor, limit]), do: id
  end

  defp selected_params(%{operation: operation} = selection) do
    states =
      case operation do
        "cancel_retries" -> @waiting
        "recover" -> @failed
        "retry" -> selection.states || @failed
      end

    [
      selection.endpoint_id,
      selection.since,
      selection.until,
      selection.event_types,
      states,
      operation == "recover",
      selection.reasons,
      operation == "cancel_retries"
    ]
  end

  # WH-31
  @doc "How many events a `replay` selection holds for `endpoint`, read by `endpoint/1`: the events of its use and consumer still kept, created in the range, of the selected types, for which the endpoint has no message."
  @spec replayed_count(selection(), map()) :: non_neg_integer()
  def replayed_count(selection, endpoint) do
    sql = "SELECT count(*) AS count FROM relay.webhook_events e WHERE #{@replayed}"
    [%{"count" => count}] = all(sql, replayed_params(selection, endpoint))
    count
  end

  # WH-31
  @doc "The identifiers of at most `limit` events of a `replay` selection after `cursor`, in identifier order."
  @spec replayed(selection(), map(), id() | nil, pos_integer()) :: [id()]
  def replayed(selection, endpoint, cursor, limit) do
    sql = """
    SELECT e.id FROM relay.webhook_events e
    WHERE #{@replayed} AND ($7::uuid IS NULL OR e.id > $7)
    ORDER BY e.id LIMIT $8
    """

    for %{"id" => id} <- all(sql, replayed_params(selection, endpoint) ++ [cursor, limit]),
        do: id
  end

  defp replayed_params(selection, endpoint) do
    [
      endpoint["use_kind"],
      endpoint["consumer_id"],
      selection.since,
      selection.until,
      selection.event_types || endpoint["event_types"],
      endpoint["id"]
    ]
  end

  # WH-48
  # TN-48
  @doc "Appends the audit record of a recovery operation on `target_id`."
  @spec audit(String.t(), String.t(), id(), String.t() | nil, binary(), Actor.t()) :: :appended
  def audit(action, target_type, target_id, reason, digest, %Actor{} = actor) do
    target = [target_type, Relay.Id.to_string(target_id), reason, nil, nil, digest]
    params = [Relay.Id.generate(), action] ++ Actor.params(actor) ++ target
    [row] = Repo.call!("relay_fn.audit_append", params)
    Repo.code!(row["audit_append"], [:appended])
  end

  defp all(sql, params) do
    %{rows: rows, columns: columns} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
