defmodule Relay.Messaging.InboundWorker do
  @moduledoc """
  The job that processes one inbound messaging receipt (WH-49, CH-62); its arguments are the scope, the receipt and the channel identity. A transient failure retries the job; a processed receipt is never processed again.
  """

  use Relay.Worker, queue: :l1, max_attempts: 10, timeout: 60_000

  # WH-49
  # CH-62
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"receipt_id" => receipt, "identity_id" => identity} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, receipt_id} <- Relay.Id.parse(receipt),
         {:ok, identity_id} <- Relay.Id.parse(identity) do
      Relay.Messaging.process(scope, receipt_id, identity_id)
    else
      {:error, _invalid} -> {:cancel, :invalid_args}
    end
  end
end
