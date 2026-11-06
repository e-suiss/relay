defmodule RelayWeb.Auth.Access do
  @moduledoc """
  The production verifier of the server API (API-41, API-48, API-71, E-93): a DPoP-bound Access access token whose audience is Relay's own Access `client_id`, checked with its proof for the request's method and external URL by `Relay.Access.verify_server_token/2` under the cached Access keys. It also names the issuer and audience of Relay's own subscriber token: issued by `<base URL>` for `<base URL>/v1/subscriber`.
  """

  @behaviour RelayWeb.Auth

  alias RelayWeb.Api.Response
  alias RelayWeb.Auth.Principal

  # API-71
  # API-48
  # E-93
  @impl RelayWeb.Auth
  def verify(token, context) do
    opts = [
      proof: Map.get(context, :proof),
      method: Map.get(context, :method),
      url: Map.get(context, :url),
      ip: Map.get(context, :ip),
      certificate: Map.get(context, :certificate)
    ]

    case Relay.Access.verify_server_token(token, opts) do
      {:ok, principal} ->
        {:ok,
         %Principal{
           scope: principal.scope,
           scopes: principal.scopes,
           subtenant_id: principal.subtenant_id,
           api_client_id: principal.api_client_id,
           certificate_bound: principal.certificate_bound
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  # E-25
  @doc "The audience of Relay's own subscriber token on this region."
  @spec audience(:subscriber) :: String.t()
  def audience(:subscriber), do: Response.base_url() <> "/v1/subscriber"

  # E-24
  # TN-25
  @doc "The issuer and audience of the subscriber token."
  @spec subscriber_audiences() :: %{issuer: String.t(), audience: String.t()}
  def subscriber_audiences, do: %{issuer: Response.base_url(), audience: audience(:subscriber)}
end
