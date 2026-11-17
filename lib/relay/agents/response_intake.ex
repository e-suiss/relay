defmodule Relay.Agents.ResponseIntake do
  @moduledoc """
  The job that processes a channel response (AG-35): the response a consumed response token carries is offered to its waitpoint after the channel was acknowledged, and the token is settled with the outcome in the same transaction. It runs on the `l1` queue, carries only identifiers (T-15) and is safe to repeat: a settled token is left as it is.
  """

  use Relay.Worker, queue: :l1, priority: 3, max_attempts: 10, timeout: 5_000

  # AG-35
  # AG-28
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"token_id" => token_id} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(token_id),
         {:ok, _outcome} <- Relay.Agents.Response.process(scope, id) do
      :ok
    end
  end
end
