defmodule Relay.Workflow.RunSweep do
  @moduledoc """
  The missed-timer sweep of workflow runs (WF-43). Every five minutes on the `maintenance` queue it lists the scopes that have a waiting run due in business time and wakes those runs, so a run whose timer job was pruned or lost is late by at most the sweep interval.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 240_000

  # WF-43
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = Relay.Workflow.sweep()
    :ok
  end
end
