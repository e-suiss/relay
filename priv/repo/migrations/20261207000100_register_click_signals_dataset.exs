defmodule Relay.Repo.Migrations.RegisterClickSignalsDataset do
  use Ecto.Migration

  # DS-30
  # DS-52
  # OP-65 (1)
  def up do
    schema =
      [:code.priv_dir(:relay), "datasets", "click_signals", "schema.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    digest = :crypto.hash(:sha256, Relay.Canonical.encode!(schema))

    repo().query!(
      "INSERT INTO relay.datasets (name, json_schema, json_schema_digest, allowed_scopes, created_at) VALUES ($1, $2, $3, $4, now()) ON CONFLICT (name) DO NOTHING",
      ["click_signals", schema, digest, ["installation"]]
    )
  end

  def down, do: :ok
end
