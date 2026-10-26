defmodule Relay.Repo.Migrations.CreatePlatformDomains do
  use Ecto.Migration

  # T-31
  # CH-7
  # C-66
  # T-29
  # C-4
  # OP-74
  def up do
    execute(~S"""
    CREATE DOMAIN relay.lane AS text
      CONSTRAINT lane_check CHECK (VALUE IN ('l0', 'l1', 'l2', 'l3'))
    """)

    execute(~S"""
    CREATE DOMAIN relay.failure_class AS text
      CONSTRAINT failure_class_check CHECK (VALUE IN ('transient', 'permanent_target',
        'permanent_content', 'policy', 'quota', 'auth', 'sender_config', 'unknown'))
    """)

    execute(~S"""
    CREATE DOMAIN relay.dlq_class AS text
      CONSTRAINT dlq_class_check CHECK (VALUE IN ('permanent', 'quality_alarm', 'exhausted',
        'budget_denied'))
    """)

    execute(~S"""
    CREATE DOMAIN relay.rule_id AS text
      CONSTRAINT rule_id_check
        CHECK (VALUE ~ '^[a-z][a-z0-9_]*([.:][A-Za-z0-9_-]+)*$' AND char_length(VALUE) <= 128)
    """)

    execute("GRANT USAGE ON SCHEMA relay_queue TO relay_owner, relay_maint")
  end
end
