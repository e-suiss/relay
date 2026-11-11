defmodule Relay.Delivery.Usage.Store do
  @moduledoc """
  The daily usage records (C-88, OP-38, INV-49, DS-53). When a UTC day has closed, the provider attempts that finished in it are counted per `(channel, provider, destination country, WhatsApp category, outcome, is_test)` of every scope and written as immutable `usage_records` rows through `relay_fn.usage_record_append`: `quantity` is the number of deliveries, `attempt_count` the number of attempts; an attempt that succeeded is `accepted`, one that stayed uncertain `uncertain` and a failed one `failed`. Test sends are their own rows (`is_test`), so billing and product metrics never mix them with live traffic.

  A row carries its billable units in the channel's unit (DS-53): SMS segments, answered voice calls with their seconds, WhatsApp messages, e-mail recipients and attempts on every other channel. Only an attempt that reached the provider, accepted or uncertain, is billable; a failed attempt and every attempt of the simulated `fake` provider count zero billable units, so their rows stay measurements and never reach an invoice.

  The dimensions come from the attempts: the destination country the channel step derived from the number's calling code and, on SMS, the segment count it measured (`relay_fn.attempt_meter`); the WhatsApp category is the one the provider's `pricing` object reported for the delivery by the end of the day (CH-60), otherwise unknown; the seconds of an answered call are the duration the provider's call report carried. The cost of a row with billable units is those units at the unit price of the provider's declaration for the country and category (CH-18), with the tier of the units already recorded in the calendar month before the day; a row without a matching price has no cost. The pricer is the channel context's (`config :relay, Relay.Delivery, pricing: Module`, by default `Relay.Channels.Live`, whose `usage_pricing/0` it calls); while it cannot read the declarations no day is written.

  Writing is idempotent: the same counts again are a `duplicate`. Different counts for a row already written are a `conflict`: the row is kept as it is and the conflict raises `[:relay, :usage, :conflict]` telemetry and an error log that alarms the operator. A day that has not closed yet is refused by the database (`day_open`). After a scope's rows are written, the provider invoices whose period covers the day are reconciled again (`Relay.Delivery.Usage.InvoiceStore`, OP-42).
  """

  alias Relay.Delivery.Usage.InvoiceStore
  alias Relay.Repo

  require Logger

  @page 100
  @pricing Relay.Channels.Live
  @outcomes [:recorded, :duplicate, :conflict, :day_open]
  @units %{
    "sms" => "segment",
    "voice" => "answered_call",
    "whatsapp" => "message",
    "email" => "recipient"
  }
  @measures ["segment_units", "answered_calls", "call_seconds"]

  @type counts :: %{
          scopes: non_neg_integer(),
          recorded: non_neg_integer(),
          duplicate: non_neg_integer(),
          conflict: non_neg_integer(),
          day_open: non_neg_integer()
        }

  @type volumes :: %{optional({String.t(), String.t()}) => non_neg_integer()}

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
    work = fn _status -> write(day, pricer) end

    with {:ok, scope} <- Relay.Scope.new(tenant_id, environment),
         {:ok, {results, drifted}} <- Repo.in_scope(scope, work) do
      InvoiceStore.alarm(scope, drifted)
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

    results =
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
            row["currency"],
            row["billable_unit"],
            row["billable_units"],
            row["voice_seconds"]
          ])

        Repo.code!(result["usage_record_append"], @outcomes)
      end

    {results, InvoiceStore.check_day(day)}
  end

  # DS-53
  @doc "The billable unit of a channel: `segment` on SMS, `answered_call` on voice, `message` on WhatsApp, `recipient` on e-mail and `attempt` on every other channel."
  @spec unit(String.t()) :: String.t()
  def unit(channel), do: Map.get(@units, channel, "attempt")

  # DS-53
  @doc "Adds the billable unit, the billable units and, on voice, the answered seconds to a counted row: only an accepted or uncertain attempt of a real provider is billable; a failed attempt and an attempt of the simulated `fake` provider count zero units."
  @spec billable(map()) :: map()
  def billable(row) do
    unit = unit(row["channel"])
    billable? = billable?(row)
    units = if billable?, do: units(row, unit), else: 0

    seconds = if row["channel"] == "voice", do: (billable? && row["call_seconds"]) || 0

    row
    |> Map.drop(@measures)
    |> Map.merge(%{
      "billable_unit" => unit,
      "billable_units" => units,
      "voice_seconds" => seconds
    })
  end

  defp billable?(%{"provider" => "fake"}), do: false
  defp billable?(%{"outcome" => outcome}), do: outcome in ["accepted", "uncertain"]

  defp units(row, "segment"), do: row["segment_units"] || 0
  defp units(row, "answered_call"), do: row["answered_calls"] || 0
  defp units(row, _unit), do: row["attempt_count"] || 0

  # CH-18
  # OP-38
  # DS-53
  @doc "Prices one counted row: a row with billable units gets `cost_micros` and `currency` from `pricer` (`Relay.Channels.Live.usage_pricing/0`) at the tier of `volumes`, the month's earlier billable units per `{channel, provider}`, for its billable units (its messages when the provider prices SMS by the message); a row without billable units or without a price is returned as it is."
  @spec price(map(), function(), volumes()) :: map()
  def price(%{"billable_units" => units} = row, _pricer, _volumes) when units in [0, nil], do: row

  def price(row, pricer, volumes) do
    %{"channel" => channel, "provider" => provider} = row
    volume = Map.get(volumes, {channel, provider}, 0)
    country = row["destination_country"]

    case pricer.(provider, channel, country, row["whatsapp_category"], volume) do
      {:ok, found} ->
        cost = found.unit_price_micros * priced_units(row, found.unit)
        Map.merge(row, %{"cost_micros" => cost, "currency" => found.currency})

      _unpriced ->
        row
    end
  end

  defp priced_units(%{"channel" => "sms"} = row, "message"), do: row["attempt_count"]
  defp priced_units(row, _unit), do: row["billable_units"]

  defp volumes(day) do
    %Postgrex.Result{rows: rows} =
      Repo.scoped_query!(
        """
        SELECT u.channel::text, u.provider,
          coalesce(sum(coalesce(u.billable_units,
            CASE WHEN u.channel = 'sms' THEN u.sms_segments ELSE u.attempt_count END)), 0)::bigint
        FROM relay.usage_records u
        WHERE u.usage_day >= date_trunc('month', $1::date)::date AND u.usage_day < $1::date
          AND u.outcome IN ('accepted', 'uncertain')
        GROUP BY u.channel, u.provider
        """,
        [day]
      )

    Map.new(rows, fn [channel, provider, units] -> {{channel, provider}, units} end)
  end

  # INV-49
  # DS-53
  @doc "The counted rows of a closed day in the current scope: channel, provider, destination country, WhatsApp category, test flag, outcome, deliveries, attempts, SMS segments and the billable units of `billable/1`."
  @spec rows(Date.t()) :: [map()]
  def rows(%Date{} = day) do
    %Postgrex.Result{columns: columns, rows: rows} =
      Repo.scoped_query!(
        ~S"""
        SELECT a.tenant_id, a.environment, d.channel::text AS channel, a.provider, n.is_test,
          CASE a.state WHEN 'failed' THEN 'failed' WHEN 'unknown' THEN 'uncertain'
            ELSE 'accepted' END AS outcome,
          a.destination_country,
          CASE WHEN d.channel = 'whatsapp' THEN w.category END AS whatsapp_category,
          count(DISTINCT a.delivery_id) AS quantity, count(*) AS attempt_count,
          CASE WHEN d.channel = 'sms' THEN sum(a.sms_segments)::bigint END AS sms_segments,
          sum(coalesce(a.sms_segments, 1))::bigint AS segment_units,
          count(DISTINCT a.delivery_id) FILTER (WHERE d.delivered_at IS NOT NULL)
            AS answered_calls,
          sum(v.seconds)::bigint AS call_seconds
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
        LEFT JOIN LATERAL (
          SELECT max((e.detail ->> 'CallDuration')::bigint) AS seconds
          FROM relay.delivery_events e
          WHERE e.tenant_id = a.tenant_id AND e.environment = a.environment
            AND e.delivery_id = a.delivery_id AND e.detail ->> 'CallDuration' ~ '^[0-9]{1,9}$'
            AND e.received_at >= $1::date::timestamptz - interval '7 days'
            AND e.received_at < ($1::date + 1)::timestamptz
        ) v ON d.channel = 'voice'
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

    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new() |> billable()))
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
