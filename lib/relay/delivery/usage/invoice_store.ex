defmodule Relay.Delivery.Usage.InvoiceStore do
  @moduledoc """
  Usage and invoice reconciliation (OP-38, OP-42, CH-18). A provider invoice of a tenant environment is recorded once per provider and invoice reference with its period, currency, amount and the raw invoice object, and is never changed: the same reference with other figures is a `conflict`. Reconciliation compares the invoice with the immutable usage records of its provider, channel and period (`relay_fn.provider_invoice_check`): the usage cost in the invoice's currency, the billable units, the billable units without a price in that currency, and the drift of the invoice amount from the usage cost in micros and basis points. A drift above the tolerance (`config :relay, Relay.Delivery, invoice_tolerance_bp: n`, 100 basis points of the larger amount by default) is `drift`, otherwise `matched`.

  An invoice is reconciled when it is recorded and again every time a usage day of its period is written; a check that reaches `drift` raises `[:relay, :usage, :invoice_drift]` telemetry and a warning log. Billing never reads metrics (DS-38).
  """

  alias Relay.Actor
  alias Relay.Repo

  require Logger

  @tolerance_bp 100
  @columns "id, provider, channel::text AS channel, invoice_ref, period_start, period_end, currency, amount_micros, units, raw, checked_at, usage_cost_micros, usage_units, unpriced_units, drift_micros, drift_bp, check_result, created_at, updated_at"

  @type digest :: <<_::256>>

  @doc "The drift tolerance in basis points."
  @spec tolerance_bp() :: non_neg_integer()
  def tolerance_bp do
    :relay
    |> Application.get_env(Relay.Delivery, [])
    |> Keyword.get(:invoice_tolerance_bp, @tolerance_bp)
  end

  # OP-38
  # OP-42
  @doc "Records a provider invoice in the established scope; `:exists` for the same figures under the same reference, `:conflict` for other figures."
  @spec record(map(), digest(), Actor.t()) :: {:recorded | :exists | :conflict, Relay.Id.t()}
  def record(i, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.provider_invoice_record",
        [
          i.id,
          i.provider,
          Map.get(i, :channel),
          i.invoice_ref,
          i.period_start,
          i.period_end,
          i.currency,
          i.amount_micros,
          Map.get(i, :units),
          Map.get(i, :raw),
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:recorded, :exists, :conflict]), row["invoice_id"]}
  end

  # OP-42
  @doc "Reconciles one invoice with the usage records of its period in the established scope."
  @spec check(Relay.Id.t()) :: {:changed | :unchanged | :not_found, :matched | :drift | nil}
  def check(id) do
    [row] = Repo.call!("relay_fn.provider_invoice_check", [id, tolerance_bp()])
    result = Repo.code!(row["result"], [:changed, :unchanged, :not_found])
    {result, row["check_result"] && Repo.code!(row["check_result"], [:matched, :drift])}
  end

  # OP-42
  @doc "Reconciles the invoices whose period covers `day` in the established scope and returns the identifiers of those that reached `drift`."
  @spec check_day(Date.t()) :: [Relay.Id.t()]
  def check_day(%Date{} = day) do
    %Postgrex.Result{rows: rows} =
      Repo.scoped_query!(
        """
        SELECT i.id FROM relay.provider_invoices i
        WHERE i.period_start <= $1::date AND i.period_end > $1::date
        ORDER BY i.id
        """,
        [day]
      )

    for [id] <- rows, check(id) == {:changed, :drift}, do: id
  end

  # OP-42
  @doc "Raises the drift alarm of invoices that reached `drift`."
  @spec alarm(Relay.Scope.t(), [Relay.Id.t()]) :: :ok
  def alarm(scope, ids) do
    for id <- ids do
      :telemetry.execute([:relay, :usage, :invoice_drift], %{count: 1}, %{})

      Logger.warning("a provider invoice drifts from the usage records of its period",
        tenant_id: Relay.Id.to_string(scope.tenant_id),
        environment: scope.environment,
        invoice_id: Relay.Id.to_string(id)
      )
    end

    :ok
  end

  @doc "Reads an invoice of the established scope, or `nil`."
  @spec get(Relay.Id.t()) :: map() | nil
  def get(id) do
    case all("SELECT #{@columns} FROM relay.provider_invoices WHERE id = $1", [id]) do
      [row] -> row
      [] -> nil
    end
  end

  # API-56
  @doc "A page of invoices newest first from a decoded cursor; at most `limit + 1` rows come back."
  @spec page(map() | nil, pos_integer()) :: [map()]
  def page(nil, limit) do
    all(
      "SELECT #{@columns} FROM relay.provider_invoices ORDER BY created_at DESC, id DESC LIMIT $1",
      [limit + 1]
    )
  end

  def page(%{direction: :after, sort_ts_us: ts, id: id}, limit) do
    all(
      "SELECT #{@columns} FROM relay.provider_invoices WHERE (created_at, id) < ($1, $2) ORDER BY created_at DESC, id DESC LIMIT $3",
      [DateTime.from_unix!(ts, :microsecond), id, limit + 1]
    )
  end

  def page(%{direction: :before, sort_ts_us: ts, id: id}, limit) do
    "SELECT #{@columns} FROM relay.provider_invoices WHERE (created_at, id) > ($1, $2) ORDER BY created_at, id LIMIT $3"
    |> all([DateTime.from_unix!(ts, :microsecond), id, limit + 1])
    |> Enum.reverse()
  end

  defp all(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
