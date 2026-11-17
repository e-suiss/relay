defmodule Relay.Repo.Migrations.AllowEvidenceLevelRejections do
  use Ecto.Migration

  # AG-62
  # AG-32
  # AG-28
  def up do
    execute("""
    ALTER TABLE relay.waitpoint_response_rejections
      ADD CONSTRAINT waitpoint_response_rejections_reason_kind_check
      CHECK (reason IN ('expired', 'closed', 'not_responder', 'is_waiter', 'digest_mismatch',
        'session_mismatch', 'evidence_level')) NOT VALID
    """)

    execute("""
    ALTER TABLE relay.waitpoint_response_rejections
      DROP CONSTRAINT waitpoint_response_rejections_reason_check
    """)
  end

  def down, do: :ok
end
