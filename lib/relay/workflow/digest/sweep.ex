defmodule Relay.Workflow.Digest.Sweep do
  @moduledoc """
  The digest window sweep (WF-27, INV-3). Every five minutes on the `maintenance` queue it lists the scopes that have an open window without a timer or past its firing time and plans or fires those windows, so a lost timer job delays a digest by at most the sweep interval and never loses its items.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 240_000

  # WF-27
  # INV-3
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = Relay.Workflow.Digest.sweep()
    :ok
  end
end
