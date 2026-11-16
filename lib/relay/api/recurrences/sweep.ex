defmodule Relay.Api.Recurrences.Sweep do
  @moduledoc """
  The missed-timer sweep of recurrence rules (WF-43, WF-61). Every five minutes on the `maintenance` queue it lists the scopes that have a rule whose timer passed more than a minute ago in business time and fires those rules, so a lost timer delays an occurrence by at most the sweep interval; an occurrence more than PT1H late is recorded missed.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 240_000

  # WF-43
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = Relay.Api.Recurrences.sweep()
    :ok
  end
end
