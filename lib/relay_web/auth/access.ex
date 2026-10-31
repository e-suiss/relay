defmodule RelayWeb.Auth.Access do
  @moduledoc """
  The production verifier of the server API (API-41, API-48, API-71): an Access client credentials token whose audience is the Relay server API of this region (`<base URL>/v1`), checked by `Relay.Access.verify_server_token/2` under the cached Access keys. It also names the audiences of the subscriber surface: the subject token of the exchange is issued for `<base URL>/v1/subscriber/token`, and a Relay subscriber token is issued by `<base URL>` for `<base URL>/v1/subscriber`.
  """

  @behaviour RelayWeb.Auth

  alias RelayWeb.Api.Response
  alias RelayWeb.Auth.Principal

  # API-71
  # API-48
  @impl RelayWeb.Auth
  def verify(token, context) do
    opts = [
      audience: audience(:server),
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

  # API-71
  # E-25
  @doc "The audience of a Relay surface on this region: `:server`, `:exchange` (the subject token of the subscriber token exchange) or `:subscriber`."
  @spec audience(:server | :exchange | :subscriber) :: String.t()
  def audience(:server), do: Response.base_url() <> "/v1"
  def audience(:exchange), do: Response.base_url() <> "/v1/subscriber/token"
  def audience(:subscriber), do: Response.base_url() <> "/v1/subscriber"

  # E-24
  # TN-25
  @doc "The issuer and audiences of the subscriber token exchange."
  @spec subscriber_audiences() :: %{
          issuer: String.t(),
          audience: String.t(),
          subject_audience: String.t()
        }
  def subscriber_audiences do
    %{
      issuer: Response.base_url(),
      audience: audience(:subscriber),
      subject_audience: audience(:exchange)
    }
  end
end
