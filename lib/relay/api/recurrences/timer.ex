defmodule Relay.Api.Recurrences.Timer do
  @moduledoc """
  The timer job of a recurrence rule's next occurrence (WF-43, WF-49). It runs on the `l1` queue at priority 3, scheduled for the occurrence's jittered instant (WF-42, WF-58), fires what the rule has due through `Relay.Api.Recurrences.fire/2` and queues the next timer in the same transaction. It never waits; it carries only identifiers (T-15). A timer that finds its rule cancelled, completed or already moved on ends without doing anything.
  """

  use Relay.Worker, queue: :l1, priority: 3, max_attempts: 10, timeout: 60_000

  # WF-43
  # WF-49
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"recurrence_id" => recurrence_id} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(recurrence_id) do
      Relay.Api.Recurrences.fire(scope, id)
    end
  end
end
