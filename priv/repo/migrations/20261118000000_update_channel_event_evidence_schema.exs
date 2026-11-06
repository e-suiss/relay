defmodule Relay.Repo.Migrations.UpdateChannelEventEvidenceSchema do
  use Ecto.Migration

  @name "channel_event_evidence"

  # CH-48
  # CH-51
  # CH-53
  # CH-75
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
