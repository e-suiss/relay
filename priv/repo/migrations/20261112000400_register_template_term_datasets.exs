defmodule Relay.Repo.Migrations.RegisterTemplateTermDatasets do
  use Ecto.Migration

  @names ["sensitive_terms", "promotional_terms"]

  # TP-46
  # TP-54
  # OP-65 (1)
  def up do
    for name <- @names do
      schema =
        [:code.priv_dir(:relay), "datasets", name, "schema.json"]
        |> Path.join()
        |> File.read!()
        |> Jason.decode!()

      digest = :crypto.hash(:sha256, Relay.Canonical.encode!(schema))

      repo().query!(
        "INSERT INTO relay.datasets (name, json_schema, json_schema_digest, allowed_scopes, created_at) VALUES ($1, $2, $3, ARRAY['installation'], now()) ON CONFLICT (name) DO NOTHING",
        [name, schema, digest]
      )
    end
  end

  def down, do: :ok
end
