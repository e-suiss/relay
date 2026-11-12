defmodule Relay.Inbox.AnnouncementTimer do
  @moduledoc """
  The expiry timer of an announcement (IN-17, IN-3, WF-43). At the announcement's `expires_at` it ends the announcement with `relay_fn.inbox_announcement_expire`, which moves the scope's announcement sequence so every reader's counters and delta see it leave. The record is the wait; the job carries only identifiers (T-15).
  """

  use Relay.Worker, queue: :l1, priority: 3, max_attempts: 10, timeout: 1_000

  # IN-17
  # WF-43
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"announcement_id" => announcement} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, announcement_id} <- Relay.Id.parse(announcement),
         {:ok, _result} <- Relay.Inbox.expire_announcement(scope, announcement_id) do
      :ok
    end
  end
end
