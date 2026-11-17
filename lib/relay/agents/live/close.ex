defmodule Relay.Agents.Live.Close do
  @moduledoc """
  The job that follows a waitpoint that was resolved, expired or cancelled (AG-35, AG-19, INV-35): the deliveries of its invitations that were not sent are cancelled and the copies already delivered are told that the request no longer awaits a response. It carries only identifiers (T-15) and may run more than once.
  """

  use Relay.Worker, queue: :l1, priority: 3, max_attempts: 10, timeout: 10_000

  # T-15
  # AG-35
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"waitpoint_id" => waitpoint_id} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(waitpoint_id),
         do: Relay.Agents.Live.close(scope, id)
  end
end
