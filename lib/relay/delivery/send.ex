defmodule Relay.Delivery.Send do
  @moduledoc """
  The job that sends one delivery. Its arguments carry the scope and identifiers only (T-15). The job, also when it starts at a delivery's `send_at`, first applies a cancellation tombstone written before the run started: a covered delivery becomes `cancelled` with the tombstone's rule (API-58, INV-6). It then reads the delivery's gate: a delivery that is cancelled, paused, expired, terminal or gone ends the job without error. Channel adapters, which hand a sendable delivery to its provider, join this job in the channel stage; until then a sendable delivery waits in the queue and the job comes back later.
  """

  use Relay.Worker, queue: :l1, max_attempts: 20, timeout: 30_000

  alias Relay.Scope

  @wait_s 300

  # T-15
  # TN-40
  # API-58
  # INV-6
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery} = args}) do
    with {:ok, scope} <- Scope.from_job_args(args),
         {:ok, delivery_id} <- Relay.Id.parse(delivery),
         {:ok, {_tombstone, _cancellation}} <- Relay.Delivery.apply_tombstone(scope, delivery_id),
         {:ok, %{result: result}} <- Relay.Delivery.gate(scope, delivery_id) do
      if result in [:sendable, :deferred], do: {:snooze, @wait_s}, else: :ok
    end
  end
end
