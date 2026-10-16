defmodule Relay.QueueRepo do
  @moduledoc """
  The job queue's maintenance connection, logged in as `relay_queue`. It has rights only in the `relay_queue` schema: the queue peer keeps its leadership rows with it and the queue cleaner removes finished job rows with it (OP-12). Only `*.Store` modules call it (T-60).
  """

  use Ecto.Repo, otp_app: :relay, adapter: Ecto.Adapters.Postgres
end
