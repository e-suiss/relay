defmodule Relay.Repo.Migrations.AddShadowRetentionClass do
  use Ecto.Migration

  @name "retention_periods"

  # OP-52 (5)
  # OP-79
  # OP-94
  # OP-65 (1)
  def up do
    execute("ALTER DOMAIN relay.retention_class DROP CONSTRAINT retention_class_check")

    execute(~S"""
    ALTER DOMAIN relay.retention_class ADD CONSTRAINT retention_class_check
      CHECK (VALUE IN ('recipient_profile', 'notification_content', 'delivery_record',
        'commercial_consent', 'commercial_message', 'preference', 'audit', 'traffic',
        'suppression', 'dsr_log', 'erasure_log', 'shadow'))
    """)

    schema =
      [:code.priv_dir(:relay), "datasets", @name, "schema.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    digest = :crypto.hash(:sha256, Relay.Canonical.encode!(schema))

    repo().query!(
      "UPDATE relay.datasets SET json_schema = $2, json_schema_digest = $3 WHERE name = $1",
      [@name, schema, digest]
    )
  end

  def down, do: :ok
end
