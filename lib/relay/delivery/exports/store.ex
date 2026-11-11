defmodule Relay.Delivery.Exports.Store do
  @moduledoc """
  Raw data exports (DS-37, OP-39, L-57, TN-18). A tenant asks for the raw rows of one kind (`deliveries`, `delivery_events` or `usage_records`) for UTC days `from` to `to` (exclusive, at most 92 days); the request is audited as `export.requested` and a job on the `maintenance` queue writes the CSV. The rows are read in pages on the report pool (`Relay.ReportRepo`, role `relay_report`) inside the tenant scope, so row level security keeps every export to its own tenant environment; the CSV is stored with its row count and SHA-256 and is ready until it expires (7 days after it was written), when its content is cleared and the row stays (`expired`). An export of more than 1,000,000 rows or 64 MiB fails as `too_large`; a narrower period is asked instead.

  The CSV is UTF-8 with a header row, `,` separators and `\\r\\n` line ends (RFC 4180); identifiers are external identifiers, times RFC 3339 UTC. A value that a spreadsheet would read as a formula gets a leading `'`. The columns carry identifiers, codes and counts only: no address, content or provider payload.
  """

  alias Relay.Actor
  alias Relay.Repo

  @page 5_000
  @max_rows 1_000_000
  @max_bytes 67_108_864
  @ttl_s 7 * 24 * 3600
  @columns "id, kind, format, period_start, period_end, state, row_count, byte_size, content_sha256, failure, requested_by, expires_at, completed_at, created_at, updated_at"

  @headers %{
    "delivery_events" => ~w(id received_at occurred_at delivery_id attempt_no actor event_type
                            provider raw_code projection_result),
    "deliveries" => ~w(id created_at notification_id channel provider is_test decision
                       decision_reason decision_rule_id delivery_rank failure_kind failure_class
                       failure_rule_id attempt_count duplicate_delivered has_conflict accepted_at
                       delivered_at),
    "usage_records" => ~w(id usage_day channel provider destination_country whatsapp_category
                          outcome is_test quantity attempt_count sms_segments billable_unit
                          billable_units voice_seconds cost_micros currency)
  }
  @prefixes %{"delivery_id" => "dlv", "notification_id" => "ntf"}
  @row_prefix %{"delivery_events" => "dle", "deliveries" => "dlv", "usage_records" => "usg"}
  @ranks %{0 => "none", 1 => "accepted", 2 => "delivered"}
  @formula [?=, ?+, ?-, ?@, ?\t, ?\r]

  @type digest :: <<_::256>>

  @doc "The export kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: ~w(deliveries delivery_events usage_records)

  # DS-37
  @doc "Records an export request in the established scope and audits it."
  @spec request(map(), digest(), Actor.t()) :: :requested
  def request(e, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.export_request",
        [e.id, e.kind, e.period_start, e.period_end, actor.ref, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["export_request"], [:requested])
  end

  @doc "Reads an export of the established scope without its content, or `nil`."
  @spec get(Relay.Id.t()) :: map() | nil
  def get(id) do
    case all("SELECT #{@columns} FROM relay.exports WHERE id = $1", [id]) do
      [row] -> row
      [] -> nil
    end
  end

  @doc "Reads the content of a ready export of the established scope, or `nil`."
  @spec content(Relay.Id.t()) :: binary() | nil
  def content(id) do
    case all("SELECT content FROM relay.exports WHERE id = $1 AND state = 'ready'", [id]) do
      [%{"content" => content}] -> content
      [] -> nil
    end
  end

  # API-56
  @doc "A page of exports newest first from a decoded cursor; at most `limit + 1` rows come back."
  @spec page(map() | nil, pos_integer()) :: [map()]
  def page(nil, limit) do
    all(
      "SELECT #{@columns} FROM relay.exports ORDER BY created_at DESC, id DESC LIMIT $1",
      [limit + 1]
    )
  end

  def page(%{direction: :after, sort_ts_us: ts, id: id}, limit) do
    all(
      "SELECT #{@columns} FROM relay.exports WHERE (created_at, id) < ($1, $2) ORDER BY created_at DESC, id DESC LIMIT $3",
      [DateTime.from_unix!(ts, :microsecond), id, limit + 1]
    )
  end

  def page(%{direction: :before, sort_ts_us: ts, id: id}, limit) do
    "SELECT #{@columns} FROM relay.exports WHERE (created_at, id) > ($1, $2) ORDER BY created_at, id LIMIT $3"
    |> all([DateTime.from_unix!(ts, :microsecond), id, limit + 1])
    |> Enum.reverse()
  end

  # DS-37
  @doc "Marks a ready export downloaded in the established scope and audits the download; an export past its expiry is expired on the way."
  @spec download(Relay.Id.t(), digest(), Actor.t()) :: :ready | :expired | :not_ready | :not_found
  def download(id, digest, %Actor{} = actor) do
    [row] = Repo.call!("relay_fn.export_download", [id, digest] ++ Actor.params(actor))
    Repo.code!(row["export_download"], [:ready, :expired, :not_ready, :not_found])
  end

  # DS-37
  @doc "Clears the content of the expired exports of the established scope and returns how many expired."
  @spec expire() :: non_neg_integer()
  def expire do
    [row] = Repo.call!("relay_fn.export_expire", [])
    row["export_expire"]
  end

  # DS-37
  # OP-39
  # TN-18
  @doc "Writes the CSV of a pending export of `scope`: reads its rows in pages on the report pool and stores the content; a content over the limits fails the export as `too_large`."
  @spec run(Relay.Scope.t(), Relay.Id.t()) ::
          {:ok, :completed | :failed | :not_pending | :not_found} | {:error, term()}
  def run(scope, id) do
    read = fn _status -> get(id) end

    with {:ok, %{"state" => "pending"} = export} <- Repo.in_scope(scope, read),
         {:ok, built} <- build(scope, export) do
      Repo.in_scope(scope, fn _status -> finish(id, built) end)
    else
      {:ok, nil} -> {:ok, :not_found}
      {:ok, %{}} -> {:ok, :not_pending}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish(id, :too_large), do: fail(id, "too_large")

  defp finish(id, {content, rows}) do
    expires_at = DateTime.add(Relay.Clock.utc_now(), @ttl_s, :second)
    sha = :crypto.hash(:sha256, content)
    [row] = Repo.call!("relay_fn.export_complete", [id, content, rows, sha, expires_at])
    Repo.code!(row["export_complete"], [:completed, :not_pending, :not_found])
  end

  # DS-37
  @doc "Fails a pending export of the established scope with `too_large` or `unavailable`."
  @spec fail(Relay.Id.t(), String.t()) :: :failed | :not_pending | :not_found
  def fail(id, failure) do
    [row] = Repo.call!("relay_fn.export_fail", [id, failure])
    Repo.code!(row["export_fail"], [:failed, :not_pending, :not_found])
  end

  defp build(scope, export) do
    kind = export["kind"]
    header = csv_line(@headers[kind])
    build(scope, export, nil, {[header], IO.iodata_length(header), 0})
  end

  defp build(scope, export, after_key, {acc, bytes, count}) do
    kind = export["kind"]
    params = [export["period_start"], export["period_end"], after_key, @page]
    read = fn _status -> rows(kind, params) end

    case Relay.ReportRepo.run(fn -> Repo.in_scope(scope, read) end) do
      {:ok, rows} ->
        lines = Enum.map(rows, &csv_line(values(kind, &1)))
        bytes = bytes + IO.iodata_length(lines)
        count = count + length(rows)
        state = {[acc | lines], bytes, count}

        cond do
          bytes > @max_bytes or count > @max_rows -> {:ok, :too_large}
          length(rows) < @page -> {:ok, {IO.iodata_to_binary(elem(state, 0)), count}}
          true -> build(scope, export, key(List.last(rows)), state)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp key(row), do: {row["sort_key"], row["id"]}

  defp rows(kind, [from, to, after_key, limit]) do
    {after_at, after_id} = after_key || {nil, nil}
    all(sql(kind), [from, to, after_at, after_id, limit])
  end

  defp sql("delivery_events") do
    """
    SELECT e.received_at AS sort_key, e.id, e.received_at, e.occurred_at, e.delivery_id,
      e.attempt_no, e.actor, e.event_type::text AS event_type, e.provider, e.raw_code,
      e.projection_result
    FROM relay.delivery_events e
    WHERE e.received_at >= $1::date::timestamptz AND e.received_at < $2::date::timestamptz
      AND ($3::timestamptz IS NULL OR (e.received_at, e.id) > ($3::timestamptz, $4::uuid))
    ORDER BY e.received_at, e.id
    LIMIT $5
    """
  end

  defp sql("deliveries") do
    """
    SELECT d.created_at AS sort_key, d.id, d.created_at, d.notification_id,
      d.channel::text AS channel, d.provider, n.is_test, d.decision, d.decision_reason,
      d.decision_rule_id, d.delivery_rank, d.failure_kind, d.failure_class, d.failure_rule_id,
      d.attempt_count, d.duplicate_delivered, d.has_conflict, d.accepted_at, d.delivered_at
    FROM relay.deliveries d
    JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
      AND n.id = d.notification_id
    WHERE d.created_at >= $1::date::timestamptz AND d.created_at < $2::date::timestamptz
      AND ($3::timestamptz IS NULL OR (d.created_at, d.id) > ($3::timestamptz, $4::uuid))
    ORDER BY d.created_at, d.id
    LIMIT $5
    """
  end

  defp sql("usage_records") do
    """
    SELECT u.usage_day::timestamptz AS sort_key, u.id, u.usage_day, u.channel::text AS channel,
      u.provider, u.destination_country, u.whatsapp_category, u.outcome, u.is_test, u.quantity,
      u.attempt_count, u.sms_segments, u.billable_unit, u.billable_units, u.voice_seconds,
      u.cost_micros, u.currency
    FROM relay.usage_records u
    WHERE u.usage_day >= $1::date AND u.usage_day < $2::date
      AND ($3::timestamptz IS NULL
        OR (u.usage_day::timestamptz, u.id) > ($3::timestamptz, $4::uuid))
    ORDER BY u.usage_day, u.id
    LIMIT $5
    """
  end

  defp values(kind, row) do
    for column <- @headers[kind], do: value(kind, column, row[column])
  end

  defp value(kind, "id", id), do: Relay.ExternalId.encode(@row_prefix[kind], id)
  defp value(_kind, "delivery_rank", rank), do: @ranks[rank]
  defp value(_kind, column, nil) when is_map_key(@prefixes, column), do: nil
  defp value(_kind, column, id) when is_map_key(@prefixes, column), do: encode(column, id)
  defp value(_kind, _column, value), do: value

  defp encode(column, id), do: Relay.ExternalId.encode(@prefixes[column], id)

  # DS-37
  @doc "One CSV line (RFC 4180) of values: `nil` is empty, times are RFC 3339 UTC, and a text a spreadsheet would read as a formula gets a leading `'`."
  @spec csv_line([term()]) :: iodata()
  def csv_line(values), do: [Enum.map_intersperse(values, ",", &field/1), "\r\n"]

  defp field(nil), do: ""
  defp field(true), do: "true"
  defp field(false), do: "false"
  defp field(n) when is_integer(n), do: Integer.to_string(n)
  defp field(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp field(%Date{} = day), do: Date.to_iso8601(day)
  defp field(text) when is_binary(text), do: text |> neutral() |> quoted()

  defp neutral(<<first, _rest::binary>> = text) when first in @formula, do: "'" <> text
  defp neutral(text), do: text

  defp quoted(text) do
    if String.contains?(text, [",", "\"", "\r", "\n"]),
      do: ["\"", String.replace(text, "\"", "\"\""), "\""],
      else: text
  end

  defp all(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
