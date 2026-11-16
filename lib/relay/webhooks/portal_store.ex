defmodule Relay.Webhooks.PortalStore do
  @moduledoc """
  Data access of the webhook portal (WH-46, WH-47): the delivery log as one consumer sees it. Every read of a message joins its endpoint and keeps only the endpoints of that consumer, so a consumer never reads a message or an attempt of another one. The only row written here is the audit record of a recovery (WH-48). Every function runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @type id :: Relay.Id.t()
  @type cursor :: map() | nil

  @failed "'failed_permanent', 'exhausted', 'expired', 'window_exceeded', 'dead_lettered', 'cancelled'"
  @missed "(m.state IN (#{@failed}) OR m.hold_reason = 'endpoint_disabled')"
  @messages "relay.webhook_messages m JOIN relay.webhook_endpoints e ON e.tenant_id = m.tenant_id AND e.environment = m.environment AND e.id = m.endpoint_id"
  @message_columns "m.id, m.endpoint_id, m.event_id, m.endpoint_version, m.event_type, m.origin, m.state, m.hold_reason, m.reason, m.total_attempt_count, m.next_attempt_at, m.last_attempt_at, m.last_response_status, m.delivered_at, m.expires_at, m.locked_until, m.created_at, m.updated_at, e.state AS endpoint_state"
  @attempt_columns "a.id, a.message_id, a.endpoint_id, a.attempt_no, a.trigger_kind, a.result, a.failure_code, a.response_status, a.duration_ms, a.webhook_timestamp, a.body_digest, a.signature, host(a.destination_ip) AS destination_ip, a.retry_after_seconds, a.started_at, a.finished_at"
  @response_columns "a.response_ct, a.response_key_id, a.response_truncated"

  # WH-30
  # WH-47
  # API-56
  @doc "A page of the messages of the endpoints of one consumer, newest first, filtered by `:endpoint_id`, `:state`, `:event_type`, `:created_after` and `:created_before` when given; `missed: true` keeps the missed events only: the messages in a terminal state other than delivered and those held because their endpoint was disabled."
  @spec messages(id(), map(), cursor(), pos_integer()) :: [map()]
  def messages(consumer_id, filters, cursor, limit) do
    where = """
    e.consumer_id = $1 AND ($2::uuid IS NULL OR m.endpoint_id = $2)
      AND ($3::text IS NULL OR m.state = $3) AND ($4::text IS NULL OR m.event_type = $4)
      AND ($5::timestamptz IS NULL OR m.created_at >= $5)
      AND ($6::timestamptz IS NULL OR m.created_at < $6)
      AND ($7::boolean IS NOT TRUE OR #{@missed})
    """

    params = [
      consumer_id,
      filters[:endpoint_id],
      filters[:state],
      filters[:event_type],
      filters[:created_after],
      filters[:created_before],
      filters[:missed] == true
    ]

    {condition, order, params} =
      case cursor do
        nil ->
          {"", "DESC", params}

        %{direction: :after, sort_ts_us: ts, id: id} ->
          {" AND (m.created_at, m.id) < ($8, $9)", "DESC", params ++ [from_us(ts), id]}

        %{direction: :before, sort_ts_us: ts, id: id} ->
          {" AND (m.created_at, m.id) > ($8, $9)", "ASC", params ++ [from_us(ts), id]}
      end

    sql = """
    SELECT #{@message_columns} FROM #{@messages}
    WHERE #{String.trim_trailing(where)}#{condition}
    ORDER BY m.created_at #{order}, m.id #{order}
    LIMIT #{limit + 1}
    """

    rows = all(sql, params)
    if order == "ASC", do: Enum.reverse(rows), else: rows
  end

  # WH-47
  @doc "Reads a message of an endpoint of one consumer with the state of its endpoint, or `nil`; a message of another consumer is `nil` too."
  @spec message(id(), id()) :: map() | nil
  def message(consumer_id, id) do
    sql = "SELECT #{@message_columns} FROM #{@messages} WHERE e.consumer_id = $1 AND m.id = $2"
    one(sql, [consumer_id, id])
  end

  # WH-10
  # API-56
  @doc "A page of the attempts of a message, in attempt order, without the answers."
  @spec attempts(id(), cursor(), pos_integer()) :: [map()]
  def attempts(message_id, cursor, limit) do
    {condition, order, params} =
      case cursor do
        nil ->
          {"", "ASC", [message_id]}

        %{direction: :after, sort_ts_us: number, id: id} ->
          {" AND (a.attempt_no, a.id) > ($2, $3)", "ASC", [message_id, number, id]}

        %{direction: :before, sort_ts_us: number, id: id} ->
          {" AND (a.attempt_no, a.id) < ($2, $3)", "DESC", [message_id, number, id]}
      end

    sql = """
    SELECT #{@attempt_columns} FROM relay.webhook_attempts a
    WHERE a.message_id = $1#{condition}
    ORDER BY a.attempt_no #{order}, a.id #{order}
    LIMIT #{limit + 1}
    """

    rows = all(sql, params)
    if order == "DESC", do: Enum.reverse(rows), else: rows
  end

  # WH-10
  @doc "Reads one attempt of a message with its sealed answer, or `nil`."
  @spec attempt(id(), id()) :: map() | nil
  def attempt(message_id, id) do
    one(
      """
      SELECT #{@attempt_columns}, #{@response_columns} FROM relay.webhook_attempts a
      WHERE a.message_id = $1 AND a.id = $2
      """,
      [message_id, id]
    )
  end

  # WH-31
  # WH-37
  @doc "The identifiers of the missed events of an endpoint created at or after `since` and, when given, before `until`, oldest first."
  @spec recoverable(id(), DateTime.t(), DateTime.t() | nil) :: [id()]
  def recoverable(endpoint_id, %DateTime{} = since, until) do
    sql = """
    SELECT m.id FROM relay.webhook_messages m
    WHERE m.endpoint_id = $1 AND m.created_at >= $2
      AND ($3::timestamptz IS NULL OR m.created_at < $3) AND #{@missed}
    ORDER BY m.created_at, m.id
    """

    for %{"id" => id} <- all(sql, [endpoint_id, since, until]), do: id
  end

  # WH-48
  # TN-47
  @doc "Appends the audit record of an action on an endpoint in the established scope."
  @spec audit(String.t(), id(), String.t(), binary(), Actor.t()) :: :ok
  def audit(action, endpoint_id, reason, digest, %Actor{} = actor) do
    [kind, ref, on_behalf_of, access_record] = Actor.params(actor)

    [_row] =
      Repo.call!("relay_fn.audit_append", [
        Relay.Id.generate(),
        action,
        kind,
        ref,
        on_behalf_of,
        access_record,
        "webhook_endpoint",
        Relay.Id.to_string(endpoint_id),
        reason,
        nil,
        nil,
        digest
      ])

    :ok
  end

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
