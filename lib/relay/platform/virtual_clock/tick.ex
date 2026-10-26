defmodule Relay.Platform.VirtualClock.Tick do
  @moduledoc """
  The job that runs after a virtual clock step commits: it calls every configured due provider (`Relay.Platform.VirtualClock.due_providers/0`) with the scope, so work that fell due in business time runs without waiting for its wall-clock timer. A provider returns `:ok` or `{:error, reason}`; a failed provider fails the job, which Oban retries.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 5, timeout: 60_000

  # TN-8
  # X-27
  # T-61 (3)
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args) do
      Relay.Platform.VirtualClock.due_providers()
      |> Enum.map(fn {module, function, extra} -> apply(module, function, [scope | extra]) end)
      |> Enum.find(:ok, &(&1 != :ok))
    end
  end
end
