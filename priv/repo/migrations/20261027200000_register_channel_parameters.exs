defmodule Relay.Repo.Migrations.RegisterChannelParameters do
  use Ecto.Migration

  @name "channel_parameters"

  # OP-65 (1)
  # CH-69
  def up do
    schema =
      [:code.priv_dir(:relay), "datasets", @name, "schema.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    digest = :crypto.hash(:sha256, Relay.Canonical.encode!(schema))

    repo().query!(
      "INSERT INTO relay.datasets (name, json_schema, json_schema_digest, allowed_scopes, created_at) VALUES ($1, $2, $3, ARRAY['installation'], now()) ON CONFLICT (name) DO NOTHING",
      [@name, schema, digest]
    )
  end

  def down, do: :ok
end
