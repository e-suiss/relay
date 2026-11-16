defmodule Relay.Api.Reports do
  @moduledoc """
  The ready-made reports on the server API (DS-35, DS-36, OP-39, CH-18, TN-18): the delivery report (funnel, outcomes and engagement with human and likely bot clicks and `machine_open` opens apart), the skip distribution by reason and `rule_id`, and the cost report from the immutable usage records, each for UTC days `from` to `to` (exclusive, at most 92 days) of the caller's tenant environment. They are read from the rollups on the report pool; test sends are their own rows and the test environment its own scope. Counts are exact; rates are left to the reader, so they are never rounded twice.
  """

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @max_days 92
  @counters ~w(accepted enqueued dispatched provider_accepted delivered engaged sdk_receipts
               skipped failed uncertain expired cancelled duplicate_delivered conflicts
               human_clicks bot_clicks opens machine_opens)
  @objects %{deliveries: "delivery_report", skips: "skip_report", costs: "cost_report"}

  # DS-35
  @doc "Reads the `from` and `to` query parameters of a report."
  @spec period(map()) :: {:ok, {Date.t(), Date.t()}} | {:error, Relay.Error.t()}
  def period(query) do
    with {:ok, from} <- date(query["from"], "/from"),
         {:ok, to} <- date(query["to"], "/to") do
      days = Date.diff(to, from)

      cond do
        days < 1 -> field("/to", "not_allowed", "the period ends after it starts")
        days > @max_days -> field("/to", "not_allowed", "a report covers at most 92 days")
        true -> {:ok, {from, to}}
      end
    end
  end

  # DS-35
  # TN-18
  @doc "Answers a report of the caller's scope."
  @spec get(Relay.Scope.t(), :deliveries | :skips | :costs, {Date.t(), Date.t()}) :: answer()
  def get(scope, kind, {from, to}) do
    case Relay.Delivery.report(scope, kind, from, to) do
      {:ok, rows} ->
        {:ok,
         {200, [],
          %{
            "object" => Map.fetch!(@objects, kind),
            "from" => Date.to_iso8601(from),
            "to" => Date.to_iso8601(to),
            "rows" => Enum.map(rows, &row(kind, &1))
          }}}

      {:error, _reason} ->
        {:error, Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})}
    end
  end

  @doc "The API view of one report row."
  @spec row(:deliveries | :skips | :costs, map()) :: map()
  def row(:deliveries, r) do
    r
    |> Map.take(@counters)
    |> Map.merge(%{
      "day" => Date.to_iso8601(r["report_day"]),
      "channel" => r["channel"],
      "provider" => if(r["provider"] == "", do: nil, else: r["provider"]),
      "is_test" => r["is_test"],
      "recomputed_at" => r["recomputed_at"]
    })
  end

  def row(:skips, r) do
    %{
      "day" => Date.to_iso8601(r["report_day"]),
      "channel" => r["channel"],
      "is_test" => r["is_test"],
      "reason" => r["reason"],
      "rule_id" => r["rule_id"],
      "skipped" => r["skipped"],
      "recomputed_at" => r["recomputed_at"]
    }
  end

  def row(:costs, r) do
    %{
      "day" => Date.to_iso8601(r["report_day"]),
      "channel" => r["channel"],
      "provider" => r["provider"],
      "destination_country" => r["destination_country"],
      "whatsapp_category" => r["whatsapp_category"],
      "outcome" => r["outcome"],
      "is_test" => r["is_test"],
      "deliveries" => r["quantity"],
      "attempts" => r["attempt_count"],
      "sms_segments" => r["sms_segments"],
      "billable_unit" => r["billable_unit"],
      "billable_units" => r["billable_units"],
      "voice_seconds" => r["voice_seconds"],
      "cost_micros" => r["cost_micros"] && Integer.to_string(r["cost_micros"]),
      "currency" => r["currency"]
    }
  end

  defp date(text, pointer) do
    case Date.from_iso8601(text || "") do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> field(pointer, "invalid_format", "not a date")
    end
  end

  defp field(pointer, code, detail) do
    {:error,
     Relay.Error.new(:validation_failed, detail, %{
       errors: [%{pointer: pointer, code: code, detail: detail}]
     })}
  end
end
