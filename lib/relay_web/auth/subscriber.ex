defmodule RelayWeb.Auth.Subscriber do
  @moduledoc """
  Authentication of the client family (API-45, IN-41): only a Relay subscriber token from the token exchange is accepted, as `Authorization: Bearer`; an Access token is never accepted on inbox, preference, device or realtime endpoints (E-25). The result names the subscriber's scope (tenant and environment from the token), the subscriber and the token's scopes.
  """

  import Plug.Conn

  alias RelayWeb.Auth.Access

  @bearer ~r/\A[Bb]earer +([A-Za-z0-9\-._~+\/]+=*)\z/

  # API-45
  # E-25
  # IN-41
  @doc "Verifies a subscriber token."
  @spec verify(String.t()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def verify(token) when is_binary(token),
    do: Relay.Access.verify_subscriber_token(token, Access.subscriber_audiences())

  # API-45
  # API-47
  @doc "Reads and verifies the subscriber token of a request."
  @spec authenticate(Plug.Conn.t()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def authenticate(conn) do
    with [value] <- get_req_header(conn, "authorization"),
         [_, token] <- Regex.run(@bearer, value) do
      verify(token)
    else
      [] -> {:error, Relay.Error.new(:auth_missing_credentials, "send a subscriber token")}
      _malformed -> {:error, Relay.Error.new(:auth_malformed_credentials, "malformed credential")}
    end
  end
end
