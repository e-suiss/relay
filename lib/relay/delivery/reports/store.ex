defmodule Relay.Delivery.Reports.Store do
  @moduledoc """
  The ready-made reports (DS-35, DS-36, OP-39, F-7). They are read from Postgres rollup tables that are derived from the ledger and can be recomputed at any time: `relay_fn.report_rollup_recompute` counts the deliveries created on a UTC day again from the deliveries, their attempts and their ledger events, per channel, provider and test flag (the delivery funnel `accepted → enqueued → dispatched → provider_accepted → delivered → engaged`, the outcomes, duplicates and conflicts, human and likely bot clicks, opens and `machine_open` opens, SDK receipts apart), and the skips of the day per channel, reason and `rule_id`. Every row is exact (DS-39); test sends are their own rows and the test environment is its own scope. Cost comes from the immutable usage records (OP-38, CH-18). There is no OLAP engine: the reports are plain queries over the rollups.

  Recomputing runs on the OLTP worker pool through `relay_fn`; reports are read on the report pool (`Relay.ReportRepo`, role `relay_report`), always inside the tenant scope, so row level security keeps every tenant's report to its own rows (TN-18).
  """

  alias Relay.Repo

  @page 100
  @counters ~w(accepted enqueued dispatched provider_accepted delivered engaged sdk_receipts
               skipped failed uncertain expired cancelled duplicate_delivered conflicts
               human_clicks bot_clicks opens machine_opens)

  @type kind :: :deliveries | :skips | :costs

  # DS-35
  # OP-39
  @doc "Recomputes the rollups of the deliveries created on `day` in the established scope and returns the rollup rows written."
  @spec recompute(Date.t()) :: %{deliveries: non_neg_integer(), skips: non_neg_integer()}
  def recompute(%Date{} = day) do
    [row] = Repo.call!("relay_fn.report_rollup_recompute", [day])
    :recomputed = Repo.code!(row["result"], [:recomputed])
    %{deliveries: row["delivery_rows"], skips: row["skip_rows"]}
  end

  # DS-35
  # OP-39
  @doc "Recomputes the rollups of `days` for every tenant scope and returns the number of scopes."
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
    work = fn _status -> Enum.each(days, &recompute/1) end

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
      Repo.in_scope(scope, fn _status -> rows(sql(kind), [from, to]) end)
    end)
  end

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
