defmodule Relay.Inbox.Timer do
  @moduledoc """
  The timer of an inbox item (IN-17, IN-9, WF-43). It runs on the `l1` queue at priority 3 at the item's expiry or snooze end, applies what is due with `relay_fn.inbox_timer_fire` (the item leaves or comes back to the list and the counters, a sequenced update is published) and schedules itself again for the next due time in the same transaction. The item row is the wait; the job never waits and carries only identifiers (T-15).
  """

  use Relay.Worker, queue: :l1, priority: 3, max_attempts: 10, timeout: 1_000

  # T-24
  # WF-43
  # IN-17
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"recipient_id" => recipient, "item_id" => item} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, recipient_id} <- Relay.Id.parse(recipient),
         {:ok, item_id} <- Relay.Id.parse(item),
         {:ok, _result} <- Relay.Inbox.fire_timer(scope, recipient_id, item_id) do
      :ok
    end
  end
end
