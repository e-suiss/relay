defmodule Relay.Repo.Migrations.ValidateDeliveryPauseAndReplayChecks do
  use Ecto.Migration

  # OP-57 (3)
  def up do
    execute("ALTER TABLE relay.deliveries VALIDATE CONSTRAINT deliveries_pause_rule_id_check")
    execute("ALTER TABLE relay.deliveries VALIDATE CONSTRAINT deliveries_replay_depth_check")

    execute(
      "ALTER TABLE relay.deliveries VALIDATE CONSTRAINT deliveries_replay_dead_letter_id_check"
    )

    execute(
      "ALTER TABLE relay.deliveries VALIDATE CONSTRAINT deliveries_replay_dead_letter_created_at_check"
    )
  end

  def down, do: :ok
end
