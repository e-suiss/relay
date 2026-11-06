defmodule Relay.Delivery.UsageDay do
  @moduledoc """
  The daily usage job (C-88, OP-38, T-87). Shortly after midnight UTC on the `maintenance` queue it writes the usage records of the UTC day that has just closed (`Relay.Delivery.Usage.Store.close_day/1`); a job with a `day` argument (`YYYY-MM-DD`) writes that day again, which only adds missing rows and raises the conflict alarm for rows that differ.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 1_800_000

  # C-88
  # OP-38
  # T-87
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    day =
      with %{"day" => text} <- args, {:ok, day} <- Date.from_iso8601(text) do
        day
      else
        _default -> Relay.Clock.utc_now() |> DateTime.to_date() |> Date.add(-1)
      end

    _ = Relay.Delivery.close_usage_day(day)
    :ok
  end
end
