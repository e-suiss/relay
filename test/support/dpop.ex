defmodule RelayTest.Dpop do
  @moduledoc "DPoP proofs for tests (RFC 9449, E-93): one ES256 proof key per test run, its RFC 7638 thumbprint for the `cnf.jkt` of the fake Access tokens, and proofs for a request's method, URL and token. Claim and header overrides make proofs that must be refused; `:key` signs with another key."

  use Boundary, top_level?: true, deps: [], exports: []

  @key :crypto.generate_key(:ecdh, :secp256r1)
  @base "https://relay.test"

  @doc "The test base URL requests are made on."
  @spec base() :: String.t()
  def base, do: @base

  @doc "A fresh ES256 key pair, for a proof of another key."
  @spec key() :: {binary(), binary()}
  def key, do: :crypto.generate_key(:ecdh, :secp256r1)

  @doc "The public JWK of a key pair; the run's proof key by default."
  @spec jwk({binary(), binary()}) :: map()
  def jwk(key \\ @key) do
    {<<4, x::binary-32, y::binary-32>>, _private} = key
    %{"kty" => "EC", "crv" => "P-256", "x" => b64(x), "y" => b64(y)}
  end

  @doc "The RFC 7638 thumbprint of a key pair's public JWK; the run's proof key by default."
  @spec jkt({binary(), binary()}) :: String.t()
  def jkt(key \\ @key) do
    %{"x" => x, "y" => y} = jwk(key)
    b64(:crypto.hash(:sha256, ~s({"crv":"P-256","kty":"EC","x":"#{x}","y":"#{y}"})))
  end

  @doc "The `Authorization: DPoP` and `DPoP` headers of a request with `token`."
  @spec headers(String.t(), atom() | String.t(), String.t()) :: [{String.t(), String.t()}]
  def headers(token, method, url),
    do: [{"authorization", "DPoP " <> token}, {"dpop", proof(method, url, token)}]

  @doc "A proof for a request: `method`, `url` and the `token` it carries (nil leaves `ath` out). Options: `:claims` and `:header` override members (a nil value removes one), `:key` signs with another key pair."
  @spec proof(atom() | String.t(), String.t(), String.t() | nil, keyword()) :: String.t()
  def proof(method, url, token, opts \\ []) do
    {_public, private} = key = Keyword.get(opts, :key, @key)
    now = System.system_time(:second)

    claims =
      %{
        "htm" => method |> to_string() |> String.upcase(),
        "htu" => url |> String.split(["?", "#"]) |> hd(),
        "iat" => now,
        "jti" => b64(:crypto.strong_rand_bytes(16))
      }
      |> put_ath(token)
      |> merge(Keyword.get(opts, :claims, %{}))

    header =
      merge(%{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => jwk(key)}, opts[:header] || %{})

    input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
    der = :crypto.sign(:ecdsa, :sha256, input, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> b64(<<r::256, s::256>>)
  end

  @doc "The `ath` of a token."
  @spec ath(String.t()) :: String.t()
  def ath(token), do: b64(:crypto.hash(:sha256, token))

  defp put_ath(claims, nil), do: claims
  defp put_ath(claims, token), do: Map.put(claims, "ath", ath(token))

  defp merge(map, overrides) do
    Enum.reduce(overrides, map, fn
      {name, nil}, acc -> Map.delete(acc, name)
      {name, value}, acc -> Map.put(acc, name, value)
    end)
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
