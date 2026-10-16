defmodule Relay.Platform.MaintRepo do
  @moduledoc """
  PostgreSQL repository connected as `relay_maint`, the BYPASSRLS maintenance role. Only `Relay.Platform.Maintenance.EscapeHatch` calls it. Its configuration is `Relay.Repo`'s with the `Relay.Platform.MaintRepo` keys applied on top (by default the user `relay_maint` and two connections); a URL of its own replaces `Relay.Repo`'s.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []
  use Ecto.Repo, otp_app: :relay, adapter: Ecto.Adapters.Postgres

  # OP-68
  @impl Ecto.Repo
  def init(_context, config) do
    base = Application.get_env(:relay, Relay.Repo, [])
    base = if Keyword.has_key?(config, :url), do: Keyword.delete(base, :url), else: base

    {:ok,
     base
     |> Keyword.put(:username, "relay_maint")
     |> Keyword.put(:pool_size, 2)
     |> Keyword.merge(config)
     |> Keyword.put(:migration_lock, false)}
  end
end
