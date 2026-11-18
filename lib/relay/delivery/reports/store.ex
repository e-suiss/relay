defmodule Relay.Delivery.Reports.Store do
  @moduledoc """
  The ready-made reports (DS-35, DS-36, OP-39, F-7). They are read from Postgres rollup tables that are derived from the ledger and can be recomputed at any time: `relay_fn.report_rollup_recompute` counts the deliveries created on a UTC day again from the deliveries, their attempts and their ledger events, per channel, provider and test flag (the delivery funnel `accepted → enqueued → dispatched → provider_accepted → delivered → engaged`, the outcomes, duplicates and conflicts, human and likely bot clicks, opens and `machine_open` opens, SDK receipts apart), and the skips of the day per channel, reason and `rule_id`; `relay_fn.report_variant_recompute` counts the deliveries of the A/B variants of workflow channel steps per workflow, step, variant, channel and test flag (WF-50: accepted, sent, delivered, seen, human and likely bot clicks), the variant read from the step results of the delivery's run. Every row is exact (DS-39); test sends are their own rows and the test environment is its own scope. Cost comes from the immutable usage records (OP-38, CH-18). There is no OLAP engine: the reports are plain queries over the rollups.

  Recomputing runs on the OLTP worker pool through `relay_fn`; reports are read on the report pool (`Relay.ReportRepo`, role `relay_report`), always inside the tenant scope, so row level security keeps every tenant's report to its own rows (TN-18).
  """

  alias Relay.Repo

  @page 100
  @counters ~w(accepted enqueued dispatched provider_accepted delivered engaged sdk_receipts
               skipped failed uncertain expired cancelled duplicate_delivered conflicts
               human_clicks bot_clicks opens machine_opens)

  @type kind :: :deliveries | :skips | :costs | :variants | :render_problems | :fallback_zones

  # DS-35
  # OP-39
  # WF-50
  @doc "Recomputes the rollups of the deliveries created on `day` in the established scope, the A/B variant rollups included, and returns the rollup rows written."
  @spec recompute(Date.t()) :: %{
          deliveries: non_neg_integer(),
          skips: non_neg_integer(),
          variants: non_neg_integer()
        }
  def recompute(%Date{} = day) do
    [row] = Repo.call!("relay_fn.report_rollup_recompute", [day])
    :recomputed = Repo.code!(row["result"], [:recomputed])
    [variants] = Repo.call!("relay_fn.report_variant_recompute", [day])
    :recomputed = Repo.code!(variants["result"], [:recomputed])

    %{
      deliveries: row["delivery_rows"],
      skips: row["skip_rows"],
      variants: variants["variant_rows"]
    }
  end

  # DS-35
  # OP-39
  @doc "Recomputes the rollups of `days` for every tenant scope, clears the content of its expired exports, and returns the number of scopes."
  @spec recompute_all([Date.t()]) :: non_neg_integer()
  def recompute_all(days), do: recompute_page(days, nil, 0)

  defp recompute_page(days, after_scope, count) do
    {tenant, environment} = after_scope || {nil, nil}
    args = [tenant, environment, @page]
    rows = Repo.call_unscoped!(:report_rollup_discovery, "relay_ops.report_rollup_scopes", args)
    scopes = for row <- rows, do: {row["tenant_id"], row["environment"]}
    count = Enum.reduce(scopes, count, &recompute_scope(days, &1, &2))

    if length(scopes) == @page, do: recompute_page(days, List.last(scopes), count), else: count
  end

  defp recompute_scope(days, {tenant_id, environment}, count) do
    work = fn _status ->
      Enum.each(days, &recompute/1)
      _expired = Relay.Delivery.Exports.Store.expire()
      :ok
    end

    with {:ok, scope} <- Relay.Scope.new(tenant_id, environment),
         {:ok, :ok} <- Repo.in_scope(scope, work) do
      count + 1
    else
      _unavailable -> count
    end
  end

  # DS-35
  # TN-18
  @doc "Reads a report of the UTC days `from` (inclusive) to `to` (exclusive) on the report pool, inside `scope`."
  @spec read(Relay.Scope.t(), kind(), Date.t(), Date.t()) :: {:ok, [map()]} | {:error, term()}
  def read(scope, kind, %Date{} = from, %Date{} = to) do
    Relay.ReportRepo.run(fn ->
      Repo.in_scope(scope, fn _status -> rows(sql(kind), params(kind, from, to)) end)
    end)
  end

  defp params(:render_problems, from, to), do: [midnight(from), midnight(to)]
  defp params(_kind, from, to), do: [from, to]

  defp midnight(day), do: DateTime.new!(day, ~T[00:00:00], "Etc/UTC")

  defp sql(:deliveries) do
    """
    SELECT r.report_day, r.channel::text AS channel, r.provider, r.is_test,
      #{Enum.join(@counters, ", ")}, r.recomputed_at
    FROM relay.report_delivery_rollups r
    WHERE r.report_day >= $1::date AND r.report_day < $2::date AND r.accepted > 0
    ORDER BY r.report_day, r.channel, r.provider, r.is_test
    """
  end

  defp sql(:skips) do
    """
    SELECT r.report_day, r.channel::text AS channel, r.is_test, r.reason, r.rule_id, r.skipped,
      r.recomputed_at
    FROM relay.report_skip_rollups r
    WHERE r.report_day >= $1::date AND r.report_day < $2::date AND r.skipped > 0
    ORDER BY r.report_day, r.channel, r.is_test, r.reason, r.rule_id
    """
  end

  # WF-50
  defp sql(:variants) do
    """
    SELECT r.report_day, r.workflow_key, r.step_key, r.variant, r.channel::text AS channel,
      r.is_test, r.accepted, r.sent, r.delivered, r.seen, r.human_clicks, r.bot_clicks,
      r.recomputed_at
    FROM relay.report_variant_rollups r
    WHERE r.report_day >= $1::date AND r.report_day < $2::date AND r.accepted > 0
    ORDER BY r.report_day, r.workflow_key, r.step_key, r.variant, r.channel, r.is_test
    """
  end

  # X-6
  # WF-46
  defp sql(:fallback_zones) do
    """
    SELECT c.count_day AS report_day, c.source, c.deliveries
    FROM relay.fallback_zone_counts c
    WHERE c.count_day >= $1::date AND c.count_day < $2::date
    ORDER BY c.count_day, c.source
    """
  end

  # TP-26
  # TP-41
  # TP-7
  defp sql(:render_problems) do
    """
    SELECT date_bin('1 day', d.created_at, timestamptz '2000-01-01 00:00:00+00') AS report_day,
      d.channel::text AS channel,
      t.key AS template, n.is_test, 'render_failed' AS problem, d.failure_reason AS reason,
      count(*) AS deliveries
    FROM relay.deliveries d
    JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
      AND n.id = d.notification_id
    LEFT JOIN relay.delivery_render_plans p ON p.tenant_id = d.tenant_id
      AND p.environment = d.environment AND p.delivery_id = d.id
    LEFT JOIN relay.templates t ON t.tenant_id = p.tenant_id AND t.environment = p.environment
      AND t.id = p.template_id
    WHERE d.created_at >= $1::timestamptz AND d.created_at < $2::timestamptz
      AND d.failure_reason IN ('missing_variable', 'render_timeout', 'output_too_large',
        'schema_violation', 'inbox_item_too_large')
    GROUP BY 1, 2, 3, 4, 6
    UNION ALL
    SELECT date_bin('1 day', d.created_at, timestamptz '2000-01-01 00:00:00+00'),
      d.channel::text, t.key, n.is_test,
      'template_locale_missing', NULL, count(*)
    FROM relay.delivery_render_plans p
    JOIN relay.deliveries d ON d.tenant_id = p.tenant_id AND d.environment = p.environment
      AND d.id = p.delivery_id
    JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
      AND n.id = d.notification_id
    JOIN relay.templates t ON t.tenant_id = p.tenant_id AND t.environment = p.environment
      AND t.id = p.template_id
    WHERE d.created_at >= $1::timestamptz AND d.created_at < $2::timestamptz
      AND p.locale_fallback
    GROUP BY 1, 2, 3, 4
    ORDER BY 1, 2, 3, 4, 5, 6
    """
  end

  defp sql(:costs) do
    """
    SELECT u.usage_day AS report_day, u.channel::text AS channel, u.provider,
      u.destination_country, u.whatsapp_category, u.outcome, u.is_test, u.quantity,
      u.attempt_count, u.sms_segments, u.billable_unit, u.billable_units, u.voice_seconds,
      u.cost_micros, u.currency
    FROM relay.usage_records u
    WHERE u.usage_day >= $1::date AND u.usage_day < $2::date
    ORDER BY u.usage_day, u.channel, u.provider, u.is_test, u.outcome,
      u.destination_country NULLS FIRST, u.whatsapp_category NULLS FIRST
    """
  end

  defp rows(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
