defmodule RelayDev.Access do
  @moduledoc """
  The local stand-in of Access for `just dev` (T-65 (1)), served to the link's HTTP client as a `Req` plug, so nothing reaches the network: it publishes the discovery document of the configured issuer, an AuthZEN configuration and a key set with one ES256 key, and mints client credentials tokens for the sample API client. The key is derived from a fixed label, so the node and a separate `mix relay.dev.token` agree on it. Relay still verifies every token through the Access link exactly as in production; only the issuer is local. Compiled in the dev and test environments only.
  """

  @behaviour Plug

  import Plug.Conn

  @kid "dev-es256"
  @ttl_s 3_600

  @doc "The issuer the stand-in answers for: the configured Access issuer."
  @spec issuer() :: String.t()
  def issuer do
    case Relay.Access.issuer() do
      issuer when is_binary(issuer) -> issuer
      _unset -> "https://access.localhost"
    end
  end

  @doc "The discovery document of the stand-in for a region."
  @spec discovery(String.t()) :: map()
  def discovery(region) do
    %{
      "issuer" => issuer(),
      "jwks_uri" => issuer() <> "/jwks",
      "token_endpoint" => issuer() <> "/oauth2/token",
      "grant_types_supported" => ["client_credentials"],
      "suiss_region" => region
    }
  end

  @doc "The public key set of the stand-in."
  @spec jwks() :: map()
  def jwks do
    {<<4, x::binary-32, y::binary-32>>, _private} = key()

    %{
      "keys" => [
        %{
          "kty" => "EC",
          "crv" => "P-256",
          "kid" => @kid,
          "alg" => "ES256",
          "use" => "sig",
          "x" => b64(x),
          "y" => b64(y)
        }
      ]
    }
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case conn.request_path do
      "/.well-known/openid-configuration" -> json(conn, discovery(region()))
      "/.well-known/authzen-configuration" -> json(conn, %{"policy_decision_point" => issuer()})
      "/jwks" -> json(conn, jwks())
      _other -> send_resp(conn, 404, "")
    end
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  @doc "Links the node to the stand-in through a real link refresh."
  @spec link() :: :ok | {:error, Relay.Error.t()}
  def link do
    case Relay.Access.refresh(http: [plug: {__MODULE__, []}]) do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # API-41
  # API-71
  @doc "A client credentials token of an Access client for the server API, valid for one hour; `audience` defaults to the server API of the running endpoint."
  @spec server_token(String.t(), String.t(), [String.t()], String.t() | nil) :: String.t()
  def server_token(access_tenant_id, client_id, scopes, audience \\ nil) do
    now = DateTime.to_unix(Relay.Clock.utc_now())

    sign(%{
      "iss" => issuer(),
      "sub" => client_id,
      "client_id" => client_id,
      "tenant_id" => access_tenant_id,
      "scope" => Enum.join(scopes, " "),
      "aud" => audience || RelayWeb.Auth.Access.audience(:server),
      "iat" => now,
      "nbf" => now,
      "exp" => now + @ttl_s
    })
  end

  defp sign(claims) do
    header = %{"alg" => "ES256", "typ" => "at+jwt", "kid" => @kid}
    input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
    {_public, private} = key()
    der = :crypto.sign(:ecdsa, :sha256, input, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> b64(<<r::256, s::256>>)
  end

  defp key,
    do: :crypto.generate_key(:ecdh, :secp256r1, :crypto.hash(:sha256, "relay-dev-access-es256"))

  @doc "The server API audience from the endpoint configuration, for a token minted while the node runs elsewhere."
  @spec configured_audience() :: String.t()
  def configured_audience do
    config = Application.get_env(:relay, RelayWeb.Endpoint, [])
    url = Keyword.get(config, :url, [])
    scheme = Keyword.get(url, :scheme, "http")
    port = Keyword.get(url, :port) || get_in(config, [:http, :port]) || 4000
    "#{scheme}://#{Keyword.get(url, :host, "localhost")}:#{port}/v1"
  end

  @doc "The installation region."
  @spec region() :: String.t()
  def region do
    {:ok, %{rows: [[region]]}} =
      Relay.Repo.unscoped_query(:installation_lookup, "SELECT region FROM relay.installation", [])

    region
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
