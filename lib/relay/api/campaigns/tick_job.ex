defmodule Relay.Api.Campaigns.TickJob do
  @moduledoc """
  The minute timer of a triggered campaign (WF-62, WF-34, T-23) on the `maintenance` queue: it carries the scope and the campaign only, runs one step of `Relay.Api.Campaigns.Engine.tick/2` and queues the next tick a minute later until the campaign closes. A long wait between stages is the campaign row's `next_stage_at`, never a running job (WF-43).
  """

  use Relay.Worker,
    queue: :maintenance,
    max_attempts: 20,
    timeout: 300_000,
    unique: [period: 50, keys: [:campaign_id], states: [:available, :scheduled]]

  @every_s 60

  # WF-62
  # WF-43
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(args["campaign_id"]) do
      case Relay.Api.Campaigns.Engine.tick(scope, id) do
        :continue -> again(args)
        :stop -> :ok
      end
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  defp again(args) do
    case Oban.insert(new(args, schedule_in: @every_s)) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
