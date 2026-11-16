defmodule Relay.Api.Campaigns.PrepareJob do
  @moduledoc """
  The preparation job of a campaign (WF-44, X-14) on the `maintenance` queue: it carries the scope and the campaign only and runs `Relay.Api.Campaigns.Preparer.run/2`, which queues the next job until the audience is evaluated.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 10, timeout: 900_000

  # WF-44
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(args["campaign_id"]) do
      Relay.Api.Campaigns.Preparer.run(scope, id)
    else
      {:error, reason} -> {:cancel, reason}
    end
  end
end
