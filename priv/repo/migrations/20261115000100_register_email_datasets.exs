defmodule Relay.Repo.Migrations.RegisterEmailDatasets do
  use Ecto.Migration

  @datasets [
    {"email_bounce_codes", ["installation"]},
    {"email_bulk_sender_rules", ["installation"]},
    {"email_reputation", ["installation"]},
    {"email_warmup_plans", ["installation", "tenant"]}
  ]

  # CH-37
  # CH-39
  # CH-41
  # CH-42
  # OP-65 (1)
  def up do
    for {name, scopes} <- @datasets do
      schema =
        [:code.priv_dir(:relay), "datasets", name, "schema.json"]
        |> Path.join()
        |> File.read!()
        |> Jason.decode!()

      digest = :crypto.hash(:sha256, Relay.Canonical.encode!(schema))

      repo().query!(
        "INSERT INTO relay.datasets (name, json_schema, json_schema_digest, allowed_scopes, created_at) VALUES ($1, $2, $3, $4, now()) ON CONFLICT (name) DO NOTHING",
        [name, schema, digest, scopes]
      )
    end
  end

  def down, do: :ok
end
