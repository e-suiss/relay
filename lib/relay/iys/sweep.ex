defmodule Relay.Iys.Sweep do
  @moduledoc """
  The İYS sweep, every fifteen minutes on the `maintenance` queue (PC-30, PC-31, PC-29, PC-60). In every scope that has an İYS configuration it expires the approvals whose three business days ended and queues again the open uploads no attempt touched (`Relay.Iys.sweep/2`). In the first sweep of every refresh interval it queues the read of each scope's authorisations and quota (`Relay.Iys.RefreshWorker`). And it reports how long the business calendar still covers: `[:relay, :iys, :calendar, :coverage]` with `days_left`, with a warning from sixty days before the end.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 600_000

  require Logger

  alias Relay.Iys.Calendar
  alias Relay.Iys.RefreshWorker
  alias Relay.Iys.Store

  @sweep_s 900
  @scopes 1_000

  # PC-30
  # PC-29
  @impl Oban.Worker
  def perform(%Oban.Job{scheduled_at: scheduled_at}) do
    now = scheduled_at || Relay.Clock.utc_now()

    scopes =
      for {tenant_id, environment} <- Store.scopes(@scopes),
          {:ok, scope} <- [Relay.Scope.new(tenant_id, environment)],
          do: scope

    Enum.each(scopes, &Relay.Iys.sweep(&1, now))
    if refresh_due?(now), do: Enum.each(scopes, &Oban.insert(RefreshWorker.job(&1)))
    _reported = coverage(now)
    :ok
  end

  # PC-29
  @doc "Whether the sweep that starts at `now` is the first of a refresh interval."
  @spec refresh_due?(DateTime.t()) :: boolean()
  def refresh_due?(%DateTime{} = now) do
    interval = Relay.Limits.seconds!(["iys", "authorisation_refresh"])
    rem(DateTime.to_unix(now), interval) < @sweep_s
  end

  # PC-60
  defp coverage(now) do
    with {:ok, calendar} <- Relay.Iys.runtime().calendar() do
      today = now |> DateTime.shift_zone!(Calendar.zone()) |> DateTime.to_date()
      reported(Calendar.coverage(calendar, today), calendar)
    end
  end

  defp reported(:ok, _calendar), do: :ok

  defp reported({:ending, days_left}, calendar) do
    :telemetry.execute([:relay, :iys, :calendar, :coverage], %{days_left: days_left}, %{})

    Logger.warning("the business calendar ends soon",
      coverage_end: Date.to_iso8601(calendar.coverage_end)
    )
  end

  defp reported(:ended, calendar) do
    :telemetry.execute([:relay, :iys, :calendar, :coverage], %{days_left: 0}, %{})

    Logger.warning("the business calendar ended",
      coverage_end: Date.to_iso8601(calendar.coverage_end)
    )
  end
end
