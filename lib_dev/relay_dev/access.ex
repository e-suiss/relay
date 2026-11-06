defmodule RelayDev.Access do
  @moduledoc """
  The local stand-in of Access for `just dev` (T-65 (1)), served to the link's HTTP client as a `Req` plug, so nothing reaches the network: it publishes the OpenID discovery document and the Suiss configuration of the configured issuer, an AuthZEN configuration and a key set with one ES256 key, and mints DPoP-bound client credentials tokens for the sample API client with the proofs that go with them (E-93). The key is derived from a fixed label, so the node and a separate `mix relay.dev.token` agree on it. Relay still verifies every token through the Access link exactly as in production; only the issuer is local. Compiled in the dev and test environments only.
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

  @doc "The OpenID discovery document of the stand-in."
  @spec discovery() :: map()
  def discovery do
    %{
      "issuer" => issuer(),
      "jwks_uri" => issuer() <> "/jwks",
      "token_endpoint" => issuer() <> "/oauth2/token",
      "grant_types_supported" => ["client_credentials"]
    }
  end

  @doc "The Suiss configuration of the stand-in for a region."
  @spec suiss(String.t()) :: map()
  def suiss(region), do: %{"issuer" => issuer(), "suiss_region" => region}

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
      "/.well-known/openid-configuration" -> json(conn, discovery())
      "/.well-known/suiss-configuration" -> json(conn, suiss(region()))
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
  # E-93
  @doc "A client credentials token of an Access client for the server API, valid for one hour: `aud` Relay's Access `client_id`, bound by `cnf.jkt` to the stand-in's DPoP key (`proof/3`)."
  @spec server_token(String.t(), String.t(), [String.t()]) :: String.t()
  def server_token(access_tenant_id, client_id, scopes) do
    now = DateTime.to_unix(Relay.Clock.utc_now())

    sign(
      %{
        "iss" => issuer(),
        "sub" => client_id,
        "client_id" => client_id,
        "access_tenant" => access_tenant_id,
        "scope" => Enum.join(scopes, " "),
        "aud" => Relay.Access.client_id() || "app_relay_dev",
        "iat" => now,
        "nbf" => now,
        "exp" => now + @ttl_s,
        "jti" => b64(:crypto.strong_rand_bytes(16)),
        "cnf" => %{"jkt" => jkt()}
      },
      "at+jwt",
      @kid,
      key()
    )
  end

  # E-93
  @doc "A DPoP proof of the stand-in's DPoP key for one request: `method`, `url` (its query is left out) and the token it carries."
  @spec proof(String.t(), String.t(), String.t()) :: String.t()
  def proof(method, url, token) do
    claims = %{
      "htm" => String.upcase(method),
      "htu" => url |> String.split(["?", "#"]) |> hd(),
      "ath" => b64(:crypto.hash(:sha256, token)),
      "iat" => DateTime.to_unix(Relay.Clock.utc_now()),
      "jti" => b64(:crypto.strong_rand_bytes(16))
    }

    sign(claims, "dpop+jwt", nil, dpop_key())
  end

  defp sign(claims, typ, kid, {_public, private}) do
    header = %{"alg" => "ES256", "typ" => typ}
    header = if kid, do: Map.put(header, "kid", kid), else: Map.put(header, "jwk", dpop_jwk())
    input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
    der = :crypto.sign(:ecdsa, :sha256, input, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> b64(<<r::256, s::256>>)
  end

  defp key,
    do: :crypto.generate_key(:ecdh, :secp256r1, :crypto.hash(:sha256, "relay-dev-access-es256"))

  defp dpop_key,
    do: :crypto.generate_key(:ecdh, :secp256r1, :crypto.hash(:sha256, "relay-dev-dpop-es256"))

  defp dpop_jwk do
    {<<4, x::binary-32, y::binary-32>>, _private} = dpop_key()
    %{"kty" => "EC", "crv" => "P-256", "x" => b64(x), "y" => b64(y)}
  end

  defp jkt do
    %{"x" => x, "y" => y} = dpop_jwk()
    thumbprint = ~s({"crv":"P-256","kty":"EC","x":"#{x}","y":"#{y}"})
    b64(:crypto.hash(:sha256, thumbprint))
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
