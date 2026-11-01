defmodule Relay.AccessClaims do
  @moduledoc """
  The names of the Access token claims Relay reads (E-79 (1)): the Access tenant in `tenant_id`, the Access client in `client_id` and the Suiss environment in `suiss_environment`. The server API, the subscriber token exchange, the ingest connectors and the command line tool read these claims only through this module, so a different name chosen by Access changes here alone.
  """

  @tenant "tenant_id"
  @client "client_id"
  @environment "suiss_environment"

  # E-79 (1)
  @doc "The claim names: `tenant`, `client` and `environment`."
  @spec names() :: %{tenant: String.t(), client: String.t(), environment: String.t()}
  def names, do: %{tenant: @tenant, client: @client, environment: @environment}

  # E-79 (1)
  @doc "The Access tenant a token's claims name, or nil."
  @spec tenant(term()) :: String.t() | nil
  def tenant(claims), do: text(claims, @tenant)

  # E-79 (1)
  @doc "The Access client a token's claims name, or nil."
  @spec client(term()) :: String.t() | nil
  def client(claims), do: text(claims, @client)

  # E-79 (1)
  @doc "The environment a token's claims name as text, or nil when they name none."
  @spec environment(term()) :: String.t() | nil
  def environment(claims), do: text(claims, @environment)

  # E-79 (1)
  # API-42
  @doc "Whether the claims name no environment or name `environment`; an unknown environment name never matches."
  @spec environment?(term(), Relay.Environment.t() | String.t()) :: boolean()
  def environment?(claims, environment) do
    case environment(claims) do
      nil -> true
      named -> same?(Relay.Environment.cast(named), Relay.Environment.cast(environment))
    end
  end

  defp same?({:ok, named}, {:ok, expected}), do: named == expected
  defp same?(_named, _expected), do: false

  # E-79 (1)
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
