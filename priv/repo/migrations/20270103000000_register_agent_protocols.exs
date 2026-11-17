defmodule Relay.Repo.Migrations.RegisterAgentProtocols do
  use Ecto.Migration

  # AG-46
  # AG-47
  # OP-65 (1)
  def up do
    schema =
      [:code.priv_dir(:relay), "datasets", "agent_protocols", "schema.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    digest = :crypto.hash(:sha256, Relay.Canonical.encode!(schema))

    repo().query!(
      "INSERT INTO relay.datasets (name, json_schema, json_schema_digest, allowed_scopes, created_at) VALUES ($1, $2, $3, ARRAY['installation'], now()) ON CONFLICT (name) DO NOTHING",
      [name(), schema, digest]
    )
  end

  def down, do: :ok

  defp name, do: "agent_protocols"
end
