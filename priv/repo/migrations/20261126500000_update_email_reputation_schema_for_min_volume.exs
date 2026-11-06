defmodule Relay.Repo.Migrations.UpdateEmailReputationSchemaForMinVolume do
  use Ecto.Migration

  @name "email_reputation"

  # CH-41
  # CH-85
  # OP-65 (1)
  def up do
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
