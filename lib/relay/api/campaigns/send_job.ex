defmodule Relay.Api.Campaigns.SendJob do
  @moduledoc """
  The send job of one fan-out sub-batch of a campaign (WF-44, T-23): it carries the scope, the campaign and the first and last member identifiers of the sub-batch only, never a recipient list, and runs `Relay.Api.Campaigns.Sender.run/4`. It waits in the tenant's DRR table on the campaign's bulk lane like any slice.
  """

  use Relay.Worker, queue: :l2, max_attempts: 5, timeout: 900_000

  # WF-44
  # T-15
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(args["campaign_id"]),
         {:ok, from} <- Relay.Id.parse(args["from"]),
         {:ok, to} <- Relay.Id.parse(args["to"]) do
      Relay.Api.Campaigns.Sender.run(scope, id, from, to)
    else
      {:error, reason} -> {:cancel, reason}
    end
  end
end
