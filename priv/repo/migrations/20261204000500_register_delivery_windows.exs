defmodule Relay.Repo.Migrations.RegisterDeliveryWindows do
  use Ecto.Migration

  # DS-18
  # DS-19
  # DS-46
  # DS-50
  # OP-65 (1)
  def up do
    schema =
      [:code.priv_dir(:relay), "datasets", "delivery_windows", "schema.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    digest = :crypto.hash(:sha256, Relay.Canonical.encode!(schema))

    repo().query!(
      "INSERT INTO relay.datasets (name, json_schema, json_schema_digest, allowed_scopes, created_at) VALUES ($1, $2, $3, $4, now()) ON CONFLICT (name) DO NOTHING",
      ["delivery_windows", schema, digest, ["installation", "tenant"]]
    )
  end

  def down, do: :ok
end
