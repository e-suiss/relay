defmodule Relay.Devices.Sweep do
  @moduledoc """
  The device sweep (CH-31, OP-44). Every hour on the `maintenance` queue it lists the scopes that have a device not seen for the stale period or the inactivity period and sweeps each of them with the contract's batch bound: stale devices are marked `stale`, inactive ones are disabled with `inactive`. A scope with more work is picked up again by the next run.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 240_000

  # CH-31
  # OP-44
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = Relay.Devices.sweep_due()
    :ok
  end
end
