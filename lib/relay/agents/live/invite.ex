defmodule Relay.Agents.Live.Invite do
  @moduledoc """
  The job of one invitation of a waitpoint (AG-28, AG-63): it turns the invitation into a notification with its deliveries, or reports it unreachable. It carries only identifiers (T-15) and may run more than once; the invitation's notification is opened once.
  """

  use Relay.Worker, queue: :l1, priority: 3, max_attempts: 10, timeout: 10_000

  # T-15
  # AG-63
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"invitation_id" => invitation_id} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(invitation_id),
         do: Relay.Agents.Live.invite(scope, id)
  end
end
