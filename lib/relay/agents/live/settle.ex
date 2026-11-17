defmodule Relay.Agents.Live.Settle do
  @moduledoc """
  The job that settles an invitation from the outcome of its deliveries (AG-63, INV-35): `delivered` once a delivery reached a surface, `unreachable` once every one of them ended without reaching one, so the next surface step is invited without waiting for the step's time. While the deliveries are still on their way it comes back later, sooner at first and at most every five minutes.
  """

  use Relay.Worker, queue: :l1, priority: 3, max_attempts: 20, timeout: 10_000

  @first_s 2
  @longest_s 300

  # T-15
  # AG-63
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"invitation_id" => invitation_id} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(invitation_id) do
      case Relay.Agents.Live.settle(scope, id) do
        {:ok, {:pending, waited_s}} -> {:snooze, wait(waited_s)}
        {:ok, _settled} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp wait(waited_s), do: waited_s |> div(4) |> max(@first_s) |> min(@longest_s)
end
