defmodule Relay.Delivery.Usage do
  @moduledoc """
  The daily usage records (C-88, OP-38, INV-49). When a UTC day has closed, the provider attempts that finished in it are counted per `(channel, provider, outcome, is_test)` of every scope and written as immutable `usage_records` rows through `relay_fn.usage_record_append`: `quantity` is the number of deliveries, `attempt_count` the number of attempts; an attempt that succeeded or stayed uncertain is `accepted`, a failed one `failed`. Test sends are their own rows (`is_test`), so billing and product metrics never mix them with live traffic.

  Writing is idempotent: the same counts again are a `duplicate`. Different counts for a row already written are a `conflict`: the row is kept as it is and the conflict raises `[:relay, :usage, :conflict]` telemetry and an error log that alarms the operator. A day that has not closed yet is refused by the database (`day_open`).
  """

  alias Relay.Repo

  require Logger

  @page 100
  @outcomes [:recorded, :duplicate, :conflict, :day_open]

  @type counts :: %{
          scopes: non_neg_integer(),
          recorded: non_neg_integer(),
          duplicate: non_neg_integer(),
          conflict: non_neg_integer(),
          day_open: non_neg_integer()
        }

  # C-88
  # OP-38
  # T-87
  @doc "Writes the usage records of a closed UTC day for every scope with finished attempts in it and returns the counts of the outcomes."
  @spec close_day(Date.t()) :: counts()
  def close_day(%Date{} = day) do
    zero = %{scopes: 0, recorded: 0, duplicate: 0, conflict: 0, day_open: 0}
    close_page(day, nil, zero)
  end

  defp close_page(day, after_scope, acc) do
    {tenant, environment} = after_scope || {nil, nil}
    args = [day, tenant, environment, @page]
    rows = Repo.call_unscoped!(:usage_day_discovery, "relay_ops.usage_day_scopes", args)
    scopes = for row <- rows, do: {row["tenant_id"], row["environment"]}
    acc = Enum.reduce(scopes, acc, &close_scope(day, &1, &2))

    if length(scopes) == @page, do: close_page(day, List.last(scopes), acc), else: acc
  end

  defp close_scope(day, {tenant_id, environment}, acc) do
    with {:ok, scope} <- Relay.Scope.new(tenant_id, environment),
         {:ok, results} <- Repo.in_scope(scope, fn _status -> write(day) end) do
      Enum.reduce(results, %{acc | scopes: acc.scopes + 1}, fn result, acc ->
        if result == :conflict, do: alarm(scope, day)
        Map.update!(acc, result, &(&1 + 1))
      end)
    else
      _unavailable -> acc
    end
  end

  defp write(day) do
    for row <- rows(day) do
      [result] =
        Repo.call!("relay_fn.usage_record_append", [
          Relay.Id.generate(),
          day,
          row["channel"],
          row["provider"],
          nil,
          nil,
          nil,
          row["outcome"],
          row["is_test"],
          row["quantity"],
          row["attempt_count"],
          nil,
          nil,
          nil
        ])

      Repo.code!(result["usage_record_append"], @outcomes)
    end
  end

  # INV-49
  @doc "The counted rows of a closed day in the current scope: channel, provider, test flag, outcome, deliveries and attempts."
  @spec rows(Date.t()) :: [map()]
  def rows(%Date{} = day) do
    %Postgrex.Result{columns: columns, rows: rows} =
      Repo.scoped_query!(
        """
        SELECT a.tenant_id, a.environment, d.channel::text AS channel, a.provider, n.is_test,
          CASE WHEN a.state = 'failed' THEN 'failed' ELSE 'accepted' END AS outcome,
          count(DISTINCT a.delivery_id) AS quantity, count(*) AS attempt_count
        FROM relay.delivery_attempts a
        JOIN relay.deliveries d ON d.tenant_id = a.tenant_id AND d.environment = a.environment
          AND d.id = a.delivery_id
        JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
          AND n.id = d.notification_id
        WHERE a.finished_at >= $1::date::timestamptz AND a.finished_at < ($1::date + 1)::timestamptz
          AND a.created_at >= $1::date::timestamptz - interval '7 days'
          AND a.created_at < ($1::date + 1)::timestamptz
          AND a.provider IS NOT NULL
        GROUP BY a.tenant_id, a.environment, d.channel, a.provider, n.is_test,
          CASE WHEN a.state = 'failed' THEN 'failed' ELSE 'accepted' END
        ORDER BY d.channel::text, a.provider, n.is_test, outcome
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
