defmodule Relay.Repo.Migrations.ValidateCorrelationDigestChecks do
  use Ecto.Migration

  # AG-65
  # OP-57
  def up do
    execute(
      "ALTER TABLE relay.waitpoints VALIDATE CONSTRAINT waitpoints_correlation_digest_check"
    )

    execute(
      "ALTER TABLE relay.waitpoint_unmatched_events VALIDATE CONSTRAINT waitpoint_unmatched_events_correlation_digest_check"
    )

    execute(
      "ALTER TABLE relay.mailbox_records VALIDATE CONSTRAINT mailbox_records_correlation_digest_check"
    )
  end

  def down, do: :ok
end
