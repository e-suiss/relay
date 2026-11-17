defmodule Relay.Webhooks.TaskNotificationWorker do
  @moduledoc """
  The job that processes the receipt of an agent task notification (AG-37, AG-42, WH-49 (1)): the notification was verified and committed before its source was answered, and it is applied to the recorded state of its task here, from the queue (`Relay.Webhooks.TaskNotifications.process/2`). Its arguments carry identifiers only (T-15).
  """

  use Relay.Worker, queue: :l1, max_attempts: 10, timeout: 60_000

  # T-15
  # AG-37
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"receipt_id" => receipt_id} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(receipt_id) do
      processed(Relay.Webhooks.process_task_notification(scope, id))
    else
      {:error, _invalid} -> {:cancel, :invalid_args}
    end
  end

  defp processed({:ok, _result}), do: :ok
  defp processed({:error, reason}), do: {:error, reason}
end
