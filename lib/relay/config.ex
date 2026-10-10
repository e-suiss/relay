defmodule Relay.Config do
  @moduledoc """
  Strict configuration validation run before the supervision tree starts. An unknown configuration key, an unknown role or an unknown `RELAY_` environment variable stops the node; there is no silent default and no key that weakens a security or compliance check.
  """

  alias Relay.Config.Error

  @app_keys [:ecto_repos, :roles, :clock, :random, Relay.Repo, RelayWeb.Endpoint]
  @os_env_keys ["RELAY_HOST", "RELAY_ROLES"]

  # INV-46
  # TN-8
  @doc "Validates application configuration and the process environment; raises `Relay.Config.Error` on any unknown key or role."
  @spec validate!(keyword(), %{optional(String.t()) => String.t()}) :: :ok
  def validate!(app_env \\ Application.get_all_env(:relay), os_env \\ System.get_env()) do
    validate_app_keys!(app_env)
    validate_roles!(Keyword.get(app_env, :roles))
    validate_os_env!(os_env)
    :ok
  end

  @doc "Configuration keys the application recognises."
  @spec known_app_keys() :: [atom()]
  def known_app_keys, do: @app_keys

  @doc "`RELAY_` environment variables the application recognises."
  @spec known_os_env_keys() :: [String.t()]
  def known_os_env_keys, do: @os_env_keys

  defp validate_app_keys!(app_env) do
    case Keyword.keys(app_env) -- @app_keys do
      [] ->
        :ok

      unknown ->
        raise Error, "unknown configuration keys for :relay: #{inspect(Enum.sort(unknown))}"
    end
  end

  defp validate_roles!(roles) when is_list(roles) and roles != [] do
    cond do
      Enum.uniq(roles) != roles ->
        raise Error, "duplicate roles: #{inspect(roles)}"

      (unknown = roles -- Relay.Role.all()) != [] ->
        raise Error, "unknown roles: #{inspect(unknown)}"

      true ->
        :ok
    end
  end

  defp validate_roles!(roles),
    do: raise(Error, "roles must be a non-empty list, got: #{inspect(roles)}")

  defp validate_os_env!(os_env) do
    unknown =
      os_env
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "RELAY_"))
      |> Enum.reject(&(&1 in @os_env_keys))
      |> Enum.sort()

    if unknown != [],
      do: raise(Error, "unknown environment variables: #{Enum.join(unknown, ", ")}"),
      else: :ok
  end
end
