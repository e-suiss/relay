defmodule Relay.Repo.Migrations.RegisterWhatsappDatasets do
  use Ecto.Migration

  @datasets [
    {"whatsapp_rate_cards", ["installation"]},
    {"whatsapp_messaging_limits", ["installation"]}
  ]

  # CH-18
  # CH-58
  # CH-61
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
