defmodule Relay.Access.EventConsumer do
  @moduledoc """
  The job that applies one Access event receipt (S-69); its only argument is the receipt identifier. A transient failure retries the job; an event that cannot apply yet stays deferred.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 20, timeout: 120_000

  # E-36
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"receipt_id" => receipt_id}}) do
    {:ok, id} = Relay.Id.parse(receipt_id)
    Relay.Access.process_event(id)
  end
end
