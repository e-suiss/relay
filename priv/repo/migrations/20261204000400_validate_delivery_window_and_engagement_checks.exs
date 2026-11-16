defmodule Relay.Repo.Migrations.ValidateDeliveryWindowAndEngagementChecks do
  use Ecto.Migration

  @checks ~w(deliveries_window_stage_check deliveries_window_stage_at_check
             deliveries_failure_actor_check deliveries_failure_occurred_at_check
             deliveries_seen_source_check deliveries_read_source_check
             deliveries_clicked_source_check deliveries_clicked_by_check
             deliveries_archived_source_check)

  # OP-57 (3)
  def up do
    for name <- @checks do
      execute("ALTER TABLE relay.deliveries VALIDATE CONSTRAINT #{name}")
    end
  end

  def down, do: :ok
end
