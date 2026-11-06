defmodule Relay.AccessClaims do
  @moduledoc """
  The names of the Access token claims Relay reads (E-93, replacing E-79 (1)): the Access tenant in `access_tenant` and the Access client in `client_id`. A token names no environment; the environment is the API client registration's. The server API, the subscriber token exchange and the ingest connectors read these claims only through this module, so a different name chosen by Access changes here alone.
  """

  @tenant "access_tenant"
  @client "client_id"

  # E-93
  @doc "The claim names: `tenant` and `client`."
  @spec names() :: %{tenant: String.t(), client: String.t()}
  def names, do: %{tenant: @tenant, client: @client}

  # E-93
  @doc "The Access tenant a token's claims name, or nil."
  @spec tenant(term()) :: String.t() | nil
  def tenant(claims), do: text(claims, @tenant)

  # E-93
  @doc "The Access client a token's claims name, or nil."
  @spec client(term()) :: String.t() | nil
  def client(claims), do: text(claims, @client)

  # E-93
  @doc "The claims naming an Access tenant and client, as an Access token carries them."
  @spec build(String.t(), String.t()) :: %{String.t() => String.t()}
  def build(tenant, client), do: %{@tenant => tenant, @client => client}

  defp text(%{} = claims, name) do
    case Map.get(claims, name) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp text(_claims, _name), do: nil
end
