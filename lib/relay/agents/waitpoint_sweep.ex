defmodule Relay.Agents.WaitpointSweep do
  @moduledoc """
  The missed-timer sweep (T-24, S-61). Every five minutes on the `maintenance` queue it lists the scopes that have a waitpoint timer due in business time and fires those waitpoints, so a timer job that was pruned or lost delays a deadline by at most the sweep interval. Then it reports the agent operations gauges of the installation (`Relay.Agents.Operations`, AG-54, AG-71); they are measured here and not when a waitpoint changes, since a silent waitpoint is one that does not change.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 240_000

  alias Relay.Agents.Operations

  # T-24
  # AG-54
  # AG-71
  @impl Oban.Worker
  def perform(%Oban.Job{scheduled_at: scheduled_at}) do
    _ = Relay.Agents.Waitpoint.sweep()
    now = scheduled_at || Relay.Clock.utc_now()
    Operations.report(Operations.overview(now))
  end
end
