defmodule Relay.Access.Dpop do
  @moduledoc """
  The DPoP proof (RFC 9449) every Access access token travels with (E-93). Access issues no bearer token: an access token carries the RFC 7638 thumbprint of its proof key in `cnf.jkt`, and each request carries a `DPoP` header with a fresh proof signed by that key.

  A proof is a compact JWS whose header has `typ` `dpop+jwt`, an allowed `alg` (`ES256`, or `Ed25519` under either name, E-79 (2)) and the public `jwk` it is signed with; its claims name the request's method (`htm`) and URL without query and fragment (`htu`), the token's hash (`ath`, the unpadded base64url SHA-256 of the token), a unique `jti` and an `iat` within 60 seconds of now. The thumbprint of the `jwk` must be the token's `cnf.jkt`. A `jti` is accepted once per proof key: it is claimed on Valkey for twice the `iat` window, and while Valkey cannot answer no proof is accepted.

  Every refusal is `auth_invalid_token` with the `invalid_dpop_proof` challenge; a token without `cnf.jkt` is `auth_invalid_token`.
  """

  alias Relay.Access.Jose
  alias Relay.Access.Token

  @typ "dpop+jwt"
  @algorithms ["ES256", "Ed25519", "EdDSA"]
  @window_s 60
  @replay_ms 2 * @window_s * 1000
  @max_jti 256

  @type request :: %{method: String.t(), url: String.t(), now: integer()}
  @type proved :: %{jti: String.t(), iat: integer(), jkt: String.t()}

  # E-93
  @doc "The algorithms a proof may be signed with."
  @spec algorithms() :: [String.t(), ...]
  def algorithms, do: @algorithms

  # E-93
  @doc "Verifies the DPoP proof of `token` (whose verified claims are `claims`) for `request` and claims its `jti`."
  @spec check(String.t() | nil, String.t(), map(), request()) :: :ok | {:error, Relay.Error.t()}
  def check(proof, token, claims, request) do
    with {:ok, jkt} <- bound(claims),
         {:ok, proved} <- verify(proof, token, jkt, request),
         do: admit(proved)
  end

  defp bound(%{"cnf" => %{"jkt" => jkt}}) when is_binary(jkt) and byte_size(jkt) == 43,
    do: {:ok, jkt}

  defp bound(_claims),
    do: {:error, Relay.Error.new(:auth_invalid_token, "the token is not bound to a DPoP key")}

  # E-93
  @doc "Verifies a proof for `token`, bound to the thumbprint `jkt`, against `request`; it does not claim the `jti`."
  @spec verify(String.t() | nil, String.t(), String.t(), request()) ::
          {:ok, proved()} | {:error, Relay.Error.t()}
  def verify(proof, token, jkt, request) when is_binary(proof) do
    with {:ok, header} <- header(proof),
         {:ok, key, thumbprint} <- key(header),
         :ok <- same(thumbprint, jkt, "the proof key is not the token's key"),
         {:ok, _header, claims} <- signed(proof, key) do
      checked(claims, token, jkt, request)
    end
  end

  def verify(_proof, _token, _jkt, _request), do: refused("a DPoP proof is required")

  defp header(proof) do
    case Jose.peek_header(proof) do
      {:ok, %{"typ" => @typ, "alg" => alg, "jwk" => %{} = jwk} = header}
      when alg in @algorithms and is_map_key(jwk, "kty") ->
        {:ok, header}

      _other ->
        refused("the DPoP proof header is not valid")
    end
  end

  defp key(%{"alg" => alg, "jwk" => jwk} = header) do
    with {:ok, key} <- Jose.public_key(jwk),
         true <- Jose.family(alg) == key.alg,
         {:ok, thumbprint} <- thumbprint(jwk) do
      {:ok, %{key | kid: Map.get(header, "kid")}, thumbprint}
    else
      _other -> refused("the DPoP proof key is not valid")
    end
  end

  defp signed(proof, key) do
    case Jose.verify(proof, [key]) do
      {:ok, header, claims} -> {:ok, header, claims}
      {:error, _failure} -> refused("the DPoP proof signature is not valid")
    end
  end

  defp checked(claims, token, jkt, request) do
    cond do
      claims["htm"] != request.method ->
        refused("the DPoP proof names another method")

      not same_url?(claims["htu"], request.url) ->
        refused("the DPoP proof names another URL")

      not Token.same?(claims["ath"], token_hash(token)) ->
        refused("the DPoP proof names another token")

      not jti?(claims["jti"]) ->
        refused("the DPoP proof has no jti")

      not fresh?(claims["iat"], request.now) ->
        refused("the DPoP proof is not fresh")

      true ->
        {:ok, %{jti: claims["jti"], iat: claims["iat"], jkt: jkt}}
    end
  end

  defp jti?(jti), do: is_binary(jti) and byte_size(jti) in 1..@max_jti

  defp fresh?(iat, now) when is_integer(iat), do: abs(now - iat) <= @window_s
  defp fresh?(_iat, _now), do: false

  # E-93
  @doc "Claims a verified proof's `jti` for its key once; a second claim within the window is a replay."
  @spec admit(proved()) :: :ok | {:error, Relay.Error.t()}
  def admit(%{jti: jti, jkt: jkt}) do
    segments = ["dpop", jkt, Jose.encode(:crypto.hash(:sha256, jti))]

    case Relay.Platform.put_short_lived_new(
           Relay.Datasets.installation_scope(),
           segments,
           "1",
           @replay_ms
         ) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        refused("the DPoP proof was already used")

      {:error, _error} ->
        {:error, Relay.Error.new(:service_unavailable, "the DPoP proof cannot be checked now")}
    end
  end

  # E-93
  @doc "The `ath` of a token: the unpadded base64url SHA-256 of its bytes."
  @spec token_hash(String.t()) :: String.t()
  def token_hash(token) when is_binary(token), do: Jose.encode(:crypto.hash(:sha256, token))

  # E-93
  @doc "The RFC 7638 thumbprint of a public JWK, as unpadded base64url."
  @spec thumbprint(map()) :: {:ok, String.t()} | :error
  def thumbprint(%{"kty" => "EC", "crv" => crv, "x" => x, "y" => y})
      when is_binary(crv) and is_binary(x) and is_binary(y),
      do: digest([{"crv", crv}, {"kty", "EC"}, {"x", x}, {"y", y}])

  def thumbprint(%{"kty" => "OKP", "crv" => crv, "x" => x}) when is_binary(crv) and is_binary(x),
    do: digest([{"crv", crv}, {"kty", "OKP"}, {"x", x}])

  def thumbprint(%{"kty" => "RSA", "e" => e, "n" => n}) when is_binary(e) and is_binary(n),
    do: digest([{"e", e}, {"kty", "RSA"}, {"n", n}])

  def thumbprint(_jwk), do: :error

  defp digest(members) do
    json = "{" <> Enum.map_join(members, ",", &member/1) <> "}"
    {:ok, Jose.encode(:crypto.hash(:sha256, json))}
  end

  defp member({name, value}), do: Jason.encode!(name) <> ":" <> Jason.encode!(value)

  # E-93
  @doc "Whether a proof's `htu` names `url`: both without query and fragment, scheme and host compared without case and default ports left out."
  @spec same_url?(term(), String.t()) :: boolean()
  def same_url?(htu, url) when is_binary(htu) and is_binary(url) do
    case {normalize(htu), normalize(url)} do
      {{:ok, named}, {:ok, expected}} -> named == expected
      _other -> false
    end
  end

  def same_url?(_htu, _url), do: false

  defp normalize(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        scheme = String.downcase(scheme)
        port = if uri.port == URI.default_port(scheme), do: nil, else: uri.port
        {:ok, {scheme, String.downcase(host), port, uri.path || "/"}}

      _other ->
        :error
    end
  end

  defp same(a, b, message) do
    if Token.same?(a, b), do: :ok, else: refused(message)
  end

  defp refused(message) do
    details = %{challenge: "invalid_dpop_proof"}
    {:error, Relay.Error.new(:auth_invalid_token, message, details)}
  end
end
