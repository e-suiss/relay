defmodule Relay.Repo.Migrations.AddDeliveryPauseAndReplayColumns do
  use Ecto.Migration

  # TN-40
  # T-29 (4)
  # OP-57 (3)
  def up do
    execute("""
    ALTER TABLE relay.deliveries
      ADD COLUMN paused_at timestamptz,
      ADD COLUMN pause_rule_id relay.rule_id,
      ADD COLUMN pause_kill_switch_id uuid,
      ADD COLUMN replay_depth smallint NOT NULL DEFAULT 0,
      ADD COLUMN replay_dead_letter_id uuid,
      ADD COLUMN replay_dead_letter_created_at timestamptz
    """)

    execute("""
    ALTER TABLE relay.deliveries ADD CONSTRAINT deliveries_pause_rule_id_check
      CHECK ((paused_at IS NULL) = (pause_rule_id IS NULL)) NOT VALID
    """)

    execute("""
    ALTER TABLE relay.deliveries ADD CONSTRAINT deliveries_replay_depth_check
      CHECK (replay_depth IN (0, 1)) NOT VALID
    """)

    execute("""
    ALTER TABLE relay.deliveries ADD CONSTRAINT deliveries_replay_dead_letter_id_check
      CHECK ((replay_depth = 1) = (replay_dead_letter_id IS NOT NULL)) NOT VALID
    """)

    execute("""
    ALTER TABLE relay.deliveries ADD CONSTRAINT deliveries_replay_dead_letter_created_at_check
      CHECK ((replay_dead_letter_id IS NULL) = (replay_dead_letter_created_at IS NULL)) NOT VALID
    """)
  end
end
