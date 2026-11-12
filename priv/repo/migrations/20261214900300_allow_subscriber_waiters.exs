defmodule Relay.Repo.Migrations.AllowSubscriberWaiters do
  use Ecto.Migration

  # WF-12
  # OP-57
  def up do
    execute("""
    ALTER TABLE relay.waitpoints ADD CONSTRAINT waitpoints_waiter_kind_subscriber_check
      CHECK (waiter_kind IN ('agent', 'api_client', 'subscriber')) NOT VALID
    """)
  end

  def down, do: :ok
end
