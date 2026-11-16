defmodule Relay.Repo.Migrations.AddDeliveryWindowAndEngagementColumns do
  use Ecto.Migration

  @sources "('inbox_action', 'provider_signal', 'client_sdk', 'tracked_link')"

  @checks [
    {"deliveries_window_stage_check", "window_stage IN (0, 1, 2)"},
    {"deliveries_window_stage_at_check", "(window_stage = 0) = (window_stage_at IS NULL)"},
    {"deliveries_failure_actor_check", "failure_actor IN ('provider_webhook', 'provider_api')"},
    {"deliveries_failure_occurred_at_check",
     "failure_kind IS NULL OR failure_occurred_at IS NOT NULL"},
    {"deliveries_seen_source_check",
     "(seen_at IS NULL) = (seen_source IS NULL) AND seen_source IN #{@sources}"},
    {"deliveries_read_source_check",
     "(read_at IS NULL) = (read_source IS NULL) AND read_source IN #{@sources}"},
    {"deliveries_clicked_source_check",
     "(clicked_at IS NULL) = (clicked_source IS NULL) AND clicked_source IN #{@sources}"},
    {"deliveries_clicked_by_check",
     "(clicked_at IS NULL) = (clicked_by IS NULL) AND clicked_by IN ('human', 'likely_bot')"},
    {"deliveries_archived_source_check",
     "(archived_at IS NULL) = (archived_source IS NULL) AND archived_source IN #{@sources}"}
  ]

  # DS-3
  # DS-4 (2)
  # DS-7
  # DS-18
  # INV-5
  # OP-57 (3)
  def up do
    execute("""
    ALTER TABLE relay.deliveries
      ADD COLUMN window_stage smallint NOT NULL DEFAULT 0,
      ADD COLUMN window_stage_at timestamptz,
      ADD COLUMN failure_actor text,
      ADD COLUMN seen_at timestamptz,
      ADD COLUMN seen_source text,
      ADD COLUMN read_at timestamptz,
      ADD COLUMN read_source text,
      ADD COLUMN clicked_at timestamptz,
      ADD COLUMN clicked_source text,
      ADD COLUMN clicked_by text,
      ADD COLUMN archived_at timestamptz,
      ADD COLUMN archived_source text
    """)

    for {name, check} <- @checks do
      execute("ALTER TABLE relay.deliveries ADD CONSTRAINT #{name} CHECK (#{check}) NOT VALID")
    end
  end

  def down, do: :ok
end
