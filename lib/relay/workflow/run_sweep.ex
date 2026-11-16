defmodule Relay.Workflow.RunSweep do
  @moduledoc """
  The missed-timer sweep of workflow runs (WF-43, WF-15). Every minute on the `maintenance` queue it lists the scopes that have a waiting run due in business time and wakes those runs, so a run whose timer job was pruned or lost is late by at most the sweep interval. A delivery outcome that changes the ledger projection outside the delivery job (a provider webhook, a reconciliation, an engagement event) makes the run of its notification due five seconds later through a database trigger on the delivery, inside the transaction that records it; repeated outcomes within that time move the wake time no further, and this sweep wakes the run.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 240_000

  # WF-43
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = Relay.Workflow.sweep()
    :ok
  end
end
