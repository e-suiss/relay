defmodule Relay.Webhooks.CompletionWorker do
  @moduledoc """
  The job that processes the receipt of a long-running job completion notification (WH-68, WH-49 (1)): the notification was verified and committed before its source was answered, and the waitpoint it names is completed here, from the queue (`Relay.Webhooks.Completions.process/2`). Its arguments carry identifiers only (T-15).
  """

  use Relay.Worker, queue: :l1, max_attempts: 10, timeout: 60_000

  # T-15
  # WH-68
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"receipt_id" => receipt_id} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(receipt_id) do
      processed(Relay.Webhooks.process_completion(scope, id))
    else
      {:error, _invalid} -> {:cancel, :invalid_args}
    end
  end

  defp processed({:ok, _result}), do: :ok
  defp processed({:error, reason}), do: {:error, reason}
end
