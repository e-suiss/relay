defmodule Relay.Channels.Live.ReconcileSweep do
  @moduledoc """
  The reconciliation sweep (DS-22, DS-48, OP-42): every five minutes on the `maintenance` queue it queues the reconciliation rounds the `reconciliation` data set makes due at the sweep's time, one job per scope, channel and provider (`Relay.Channels.Live.Reconciliation.sweep/1`).
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 300_000

  # DS-48
  @impl Oban.Worker
  def perform(%Oban.Job{scheduled_at: scheduled_at}) do
    now = scheduled_at || Relay.Clock.utc_now()

    case Relay.Channels.Live.Reconciliation.sweep(now) do
      {:ok, _queued} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
