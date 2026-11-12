defmodule Relay.Inbox.BulkJob do
  @moduledoc """
  One chunk of an asynchronous inbox bulk action (IN-14, WF-43). It applies the next chunk of the operation with `Relay.Inbox.run_bulk/2` in one transaction, which queues the next chunk in the same transaction while matching items remain, so the action never runs as one long job and survives a restart. The job carries only the scope and the operation's identifier (T-15).
  """

  use Relay.Worker, queue: :l2, max_attempts: 10, timeout: 60_000

  # IN-14
  # WF-43
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"operation_id" => operation} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, operation_id} <- Relay.Id.parse(operation),
         {:ok, _result} <- Relay.Inbox.run_bulk(scope, operation_id) do
      :ok
    end
  end
end
