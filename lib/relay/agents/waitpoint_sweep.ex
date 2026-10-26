defmodule Relay.Agents.WaitpointSweep do
  @moduledoc """
  The missed-timer sweep (T-24, S-61). Every five minutes on the `maintenance` queue it lists the scopes that have a waitpoint timer due in business time and fires those waitpoints, so a timer job that was pruned or lost delays a deadline by at most the sweep interval.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 240_000

  # T-24
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = Relay.Agents.Waitpoint.sweep()
    :ok
  end
end
