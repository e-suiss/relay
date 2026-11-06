defmodule Relay.Delivery.Usage.Store do
  @moduledoc """
  The daily usage records (C-88, OP-38, INV-49). When a UTC day has closed, the provider attempts that finished in it are counted per `(channel, provider, destination country, WhatsApp category, outcome, is_test)` of every scope and written as immutable `usage_records` rows through `relay_fn.usage_record_append`: `quantity` is the number of deliveries, `attempt_count` the number of attempts; an attempt that succeeded is `accepted`, one that stayed uncertain `uncertain` and a failed one `failed`. Test sends are their own rows (`is_test`), so billing and product metrics never mix them with live traffic.

  The dimensions come from the attempts: the destination country the channel step derived from the number's calling code and, on SMS, the segment count it measured (`relay_fn.attempt_meter`); the WhatsApp category is the one the provider's `pricing` object reported for the delivery by the end of the day (CH-60), otherwise unknown. The cost of an `accepted` or `uncertain` row is its units (segments when the provider prices SMS by the segment, otherwise attempts) at the unit price of the provider's declaration for the country and category (CH-18), with the tier of the volume already recorded in the calendar month before the day; a row without a matching price has no cost. The pricer is the channel context's (`config :relay, Relay.Delivery, pricing: Module`, by default `Relay.Channels`, whose `usage_pricing/0` it calls); while it cannot read the declarations no day is written.

  Writing is idempotent: the same counts again are a `duplicate`. Different counts for a row already written are a `conflict`: the row is kept as it is and the conflict raises `[:relay, :usage, :conflict]` telemetry and an error log that alarms the operator. A day that has not closed yet is refused by the database (`day_open`).
  """

  alias Relay.Repo

  require Logger

  @page 100
  @pricing Relay.Channels
  @outcomes [:recorded, :duplicate, :conflict, :day_open]

  @type counts :: %{
          scopes: non_neg_integer(),
          recorded: non_neg_integer(),
          duplicate: non_neg_integer(),
          conflict: non_neg_integer(),
          day_open: non_neg_integer()
        }

  @type volumes :: %{optional({String.t(), String.t()}) => {integer(), integer()}}

  # C-88
  # OP-38
  # T-87
  @doc "Writes the usage records of a closed UTC day for every scope with finished attempts in it and returns the counts of the outcomes; `{:error, reason}` while the prices cannot be read."
  @spec close_day(Date.t()) :: counts() | {:error, term()}
  def close_day(%Date{} = day) do
    zero = %{scopes: 0, recorded: 0, duplicate: 0, conflict: 0, day_open: 0}

    case pricing().usage_pricing() do
      {:ok, pricer} -> close_page({day, pricer}, nil, zero)
      {:error, reason} -> {:error, reason}
    end
  end

  defp pricing do
    :relay |> Application.get_env(Relay.Delivery, []) |> Keyword.get(:pricing, @pricing)
  end

  defp close_page({day, _pricer} = run, after_scope, acc) do
    {tenant, environment} = after_scope || {nil, nil}
    args = [day, tenant, environment, @page]
    rows = Repo.call_unscoped!(:usage_day_discovery, "relay_ops.usage_day_scopes", args)
    scopes = for row <- rows, do: {row["tenant_id"], row["environment"]}
    acc = Enum.reduce(scopes, acc, &close_scope(run, &1, &2))

    if length(scopes) == @page, do: close_page(run, List.last(scopes), acc), else: acc
  end

  defp close_scope({day, pricer}, {tenant_id, environment}, acc) do
    with {:ok, scope} <- Relay.Scope.new(tenant_id, environment),
         {:ok, results} <- Repo.in_scope(scope, fn _status -> write(day, pricer) end) do
      Enum.reduce(results, %{acc | scopes: acc.scopes + 1}, &count(scope, day, &1, &2))
    else
      _unavailable -> acc
    end
  end

  defp count(scope, day, result, acc) do
    if result == :conflict, do: alarm(scope, day)
    Map.update!(acc, result, &(&1 + 1))
  end

  defp write(day, pricer) do
    volumes = volumes(day)

    for row <- rows(day) do
      row = price(row, pricer, volumes)

      [result] =
        Repo.call!("relay_fn.usage_record_append", [
          Relay.Id.generate(),
          day,
          row["channel"],
          row["provider"],
          row["destination_country"],
          nil,
          row["whatsapp_category"],
          row["outcome"],
          row["is_test"],
          row["quantity"],
          row["attempt_count"],
          row["sms_segments"],
          row["cost_micros"],
          row["currency"]
        ])

      Repo.code!(result["usage_record_append"], @outcomes)
    end
  end

  # CH-18
  # OP-38
  @doc "Prices one counted row: an `accepted` or `uncertain` row gets `cost_micros` and `currency` from `pricer` (`Relay.Channels.usage_pricing/0`) at the tier of `volumes`, the month's earlier units per `{channel, provider}` as `{attempts, segments}`; a failed or unpriced row is returned as it is."
  @spec price(map(), function(), volumes()) :: map()
  def price(%{"outcome" => "failed"} = row, _pricer, _volumes), do: row

  def price(row, pricer, volumes) do
    %{"channel" => channel, "provider" => provider} = row
    price = &pricer.(provider, channel, row["destination_country"], row["whatsapp_category"], &1)

    with {:ok, %{unit: unit}} <- price.(0),
         units when is_integer(units) <- units(row, unit),
         {:ok, found} <- price.(volume(volumes, {channel, provider}, unit)) do
      cost = found.unit_price_micros * units
      Map.merge(row, %{"cost_micros" => cost, "currency" => found.currency})
    else
      _unpriced -> row
    end
  end

  defp units(row, "segment"), do: row["sms_segments"]
  defp units(row, _unit), do: row["attempt_count"]

  defp volume(volumes, key, unit) do
    {messages, segments} = Map.get(volumes, key, {0, 0})
    if unit == "segment", do: segments, else: messages
  end

  defp volumes(day) do
    %Postgrex.Result{rows: rows} =
      Repo.scoped_query!(
        """
        SELECT u.channel::text, u.provider, coalesce(sum(u.attempt_count), 0)::bigint,
          coalesce(sum(u.sms_segments), 0)::bigint
        FROM relay.usage_records u
        WHERE u.usage_day >= date_trunc('month', $1::date)::date AND u.usage_day < $1::date
          AND u.outcome IN ('accepted', 'uncertain')
        GROUP BY u.channel, u.provider
        """,
        [day]
      )

    Map.new(rows, fn [channel, provider, messages, segments] ->
      {{channel, provider}, {messages, segments}}
    end)
  end

  # INV-49
  @doc "The counted rows of a closed day in the current scope: channel, provider, destination country, WhatsApp category, test flag, outcome, deliveries, attempts and SMS segments."
  @spec rows(Date.t()) :: [map()]
  def rows(%Date{} = day) do
    %Postgrex.Result{columns: columns, rows: rows} =
      Repo.scoped_query!(
        """
        SELECT a.tenant_id, a.environment, d.channel::text AS channel, a.provider, n.is_test,
          CASE a.state WHEN 'failed' THEN 'failed' WHEN 'unknown' THEN 'uncertain'
            ELSE 'accepted' END AS outcome,
          a.destination_country,
          CASE WHEN d.channel = 'whatsapp' THEN w.category END AS whatsapp_category,
          count(DISTINCT a.delivery_id) AS quantity, count(*) AS attempt_count,
          CASE WHEN d.channel = 'sms' THEN sum(a.sms_segments)::bigint END AS sms_segments
        FROM relay.delivery_attempts a
        JOIN relay.deliveries d ON d.tenant_id = a.tenant_id AND d.environment = a.environment
          AND d.id = a.delivery_id
        JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
          AND n.id = d.notification_id
        LEFT JOIN LATERAL (
          SELECT left(lower(e.detail -> 'price' ->> 'category'), 64) AS category
          FROM relay.delivery_events e
          WHERE e.tenant_id = a.tenant_id AND e.environment = a.environment
            AND e.delivery_id = a.delivery_id AND e.detail -> 'price' ->> 'category' IS NOT NULL
            AND e.received_at >= $1::date::timestamptz - interval '7 days'
            AND e.received_at < ($1::date + 1)::timestamptz
          ORDER BY e.received_at DESC, e.id DESC
          LIMIT 1
        ) w ON d.channel = 'whatsapp'
        WHERE a.finished_at >= $1::date::timestamptz
          AND a.finished_at < ($1::date + 1)::timestamptz
          AND a.created_at >= $1::date::timestamptz - interval '7 days'
          AND a.created_at < ($1::date + 1)::timestamptz
          AND a.provider IS NOT NULL
        GROUP BY a.tenant_id, a.environment, d.channel, a.provider, n.is_test, 6, 7, 8
        ORDER BY d.channel::text, a.provider, n.is_test, outcome,
          a.destination_country NULLS FIRST, whatsapp_category NULLS FIRST
        """,
        [day]
      )

    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end

  # OP-38
  defp alarm(scope, day) do
    :telemetry.execute([:relay, :usage, :conflict], %{count: 1}, %{day: Date.to_iso8601(day)})

    Logger.error("a usage record differs from the one already written; the first is kept",
      tenant_id: Relay.Id.to_string(scope.tenant_id),
      environment: scope.environment,
      day: Date.to_iso8601(day)
    )
  end
end
