defmodule Relay.Delivery.ReportRollup do
  @moduledoc """
  The report rollup job (DS-35, OP-39). On the `maintenance` queue it recomputes the report rollups of the last `days` UTC days, today included, for every tenant scope from the ledger (`Relay.Delivery.Reports.Store.recompute_all/1`): hourly the last two days, so late provider events and engagement reach the reports, and once a day the last fifteen, the longest delivery report window and its margin. A recomputation replaces the counts of the day, so running it again changes nothing. The same pass clears the content of the raw data exports that have expired (DS-37).
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 1_800_000

  @default_days 2
  @max_days 31

  # DS-35
  # OP-39
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    days =
      case args do
        %{"days" => n} when is_integer(n) and n in 1..@max_days -> n
        _default -> @default_days
      end

    today = Relay.Clock.utc_now() |> DateTime.to_date()
    _scopes = Relay.Delivery.recompute_reports(Enum.map(0..(days - 1), &Date.add(today, -&1)))
    :ok
  end
end
