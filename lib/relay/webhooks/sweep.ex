defmodule Relay.Webhooks.Sweep do
  @moduledoc """
  The sweep of the delivery engine, every minute on the `maintenance` queue (WH-28, WH-32 (4), WH-36): in every scope that has such a message it picks up the messages whose lock ran out because their worker crashed, queues again the messages that are long due without a running job, ends the messages that waited behind an open circuit breaker past their window (`window_exceeded`, with the tenant's alarm) or were held past their delivery time (`expired`), warns about and disables the endpoints whose uninterrupted failure came of age, and reports the age of the backlog (`Relay.Webhooks.sweep/0`).
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 240_000

  # WH-28
  # WH-32 (4)
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = Relay.Webhooks.sweep()
    :ok
  end
end
