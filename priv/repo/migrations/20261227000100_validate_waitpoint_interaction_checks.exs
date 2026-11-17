defmodule Relay.Repo.Migrations.ValidateWaitpointInteractionChecks do
  use Ecto.Migration

  # OP-57
  # AG-8
  # AG-53
  # AG-62
  def up do
    execute("ALTER TABLE relay.waitpoints VALIDATE CONSTRAINT waitpoints_profile_check")
    execute("ALTER TABLE relay.waitpoints VALIDATE CONSTRAINT waitpoints_outcome_class_check")
    execute("ALTER TABLE relay.waitpoints VALIDATE CONSTRAINT waitpoints_risk_tier_check")
    execute("ALTER TABLE relay.waitpoints VALIDATE CONSTRAINT waitpoints_correlation_id_check")

    execute(
      "ALTER TABLE relay.waitpoint_responses VALIDATE CONSTRAINT waitpoint_responses_value_ct_check"
    )
  end

  def down, do: :ok
end
