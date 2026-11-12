defmodule Relay.Workflow.Digest.Timer do
  @moduledoc """
  The timer job of a digest window (WF-27, WF-43). It runs on the `l1` queue at priority 3 at the window's firing time and fires the window through `Relay.Workflow.Digest.fire/2`: a window whose firing time moved later reschedules this job in the same transaction; a closed window ends it. It carries only the scope and the window identifier (T-15) and never waits.
  """

  use Relay.Worker, queue: :l1, priority: 3, max_attempts: 10, timeout: 10_000

  # T-15
  # WF-27
  # WF-43
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"window_id" => window_id} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(window_id),
         {:ok, _result} <- Relay.Workflow.Digest.fire(scope, id) do
      :ok
    end
  end
end
