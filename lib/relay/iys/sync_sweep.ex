defmodule Relay.Iys.SyncSweep do
  @moduledoc """
  The İYS synchronisation sweep, every five minutes on the `maintenance` queue (PC-32, PC-33, PC-62, OP-42). For every scope that has an İYS configuration it announces the brands whose copy became stale or fresh again (`Relay.Iys.stale_check/2`, no network) and queues the read path (`Relay.Iys.SyncWorker`), which pulls a brand when its pull interval passed. Then it reports the installation's state as gauges for the alert rules, by count only: `[:relay, :iys, :sync, :overview]` with the brands past the warning and the stop age of their copy, the brands at the warning and at the limit of the direct access threshold and the drift the reconciliations found. The gauges are measured here and not by the jobs, so a copy that goes stale because the jobs do not run is still reported.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 300_000

  alias Relay.Iys.Store
  alias Relay.Iys.SyncWorker

  @scopes 1_000

  # PC-32
  # PC-33
  @impl Oban.Worker
  def perform(%Oban.Job{scheduled_at: scheduled_at}) do
    now = scheduled_at || Relay.Clock.utc_now()

    scopes =
      for {tenant_id, environment} <- Store.scopes(@scopes),
          {:ok, scope} <- [Relay.Scope.new(tenant_id, environment)],
          do: scope

    Enum.each(scopes, &Relay.Iys.stale_check(&1, now))
    Enum.each(scopes, &Oban.insert(SyncWorker.job(&1)))
    report(Store.overview(now))
  end

  # PC-33
  # PC-62
  # OP-42
  @doc "Emits the installation's İYS synchronisation gauges from the counts of `Relay.Iys.Store.overview/1`."
  @spec report(map()) :: :ok
  def report(%{} = counts) do
    measurements = %{
      stale_warning: counts["stale_warning"],
      stale_stopped: counts["stale_stopped"],
      address_warning: counts["address_warning"],
      address_reached: counts["address_reached"],
      drift: counts["drift"]
    }

    :telemetry.execute([:relay, :iys, :sync, :overview], measurements, %{})
  end
end
