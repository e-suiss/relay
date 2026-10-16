defmodule Relay.Repo.Migrations.GrantQueueSchema do
  use Ecto.Migration

  # OP-9
  # OP-12
  # T-17
  def up do
    execute("REVOKE ALL ON SCHEMA relay_queue FROM PUBLIC")
    execute("GRANT USAGE ON SCHEMA relay_queue TO relay_app, relay_queue")
    execute("GRANT SELECT, INSERT, UPDATE ON relay_queue.oban_jobs TO relay_app")
    execute("GRANT SELECT, DELETE ON relay_queue.oban_jobs TO relay_queue")
    execute("GRANT USAGE ON SEQUENCE relay_queue.oban_jobs_id_seq TO relay_app")
    execute("GRANT SELECT ON relay_queue.oban_peers TO relay_app")
    execute("GRANT SELECT, INSERT, UPDATE, DELETE ON relay_queue.oban_peers TO relay_queue")
  end
end
