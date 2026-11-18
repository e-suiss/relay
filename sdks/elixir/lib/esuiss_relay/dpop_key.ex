defmodule EsuissRelay.DpopKey do
  @moduledoc """
  An Ed25519 key that proves possession of a DPoP-bound Access token (RFC 9449).

  Relay accepts no bearer token: every request carries `Authorization: DPoP <token>` and a fresh
  proof signed with this key. The private half never appears in `inspect/1`.
  """

  @enforce_keys [:public, :private]
  defstruct [:public, :private]

  @type t :: %__MODULE__{public: <<_::256>>, private: <<_::256>>}

  @doc "Generates a new key."
  @spec generate() :: t()
  def generate do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    %__MODULE__{public: public, private: private}
  end

  @doc "The key of a 32-byte Ed25519 seed."
  @spec from_seed(<<_::256>>) :: t()
  def from_seed(<<_::256>> = seed) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519, seed)
    %__MODULE__{public: public, private: private}
  end

  @doc "The public key as a JWK."
  @spec jwk(t()) :: map()
  def jwk(%__MODULE__{public: public}),
    do: %{"kty" => "OKP", "crv" => "Ed25519", "x" => b64(public)}

  @doc """
  A DPoP proof for one request: `method`, the request `url` (query and fragment are dropped),
  the access token it carries (`nil` at the token endpoint), an optional server nonce, the
  current Unix time and 16 random bytes for `jti`.
  """
  @spec proof(
          t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          integer(),
          binary()
        ) ::
          String.t()
  def proof(%__MODULE__{} = key, method, url, token, nonce, now, jti) do
    header = %{"typ" => "dpop+jwt", "alg" => "Ed25519", "jwk" => jwk(key)}

    claims =
      %{
        "htm" => String.upcase(method),
        "htu" => url |> String.split(["?", "#"]) |> hd(),
        "iat" => now,
        "jti" => b64(jti)
      }
      |> put("ath", token && b64(:crypto.hash(:sha256, token)))
      |> put("nonce", nonce)

    input = b64(JSON.encode!(header)) <> "." <> b64(JSON.encode!(claims))
    input <> "." <> b64(:crypto.sign(:eddsa, :none, input, [key.private, :ed25519]))
  end

  defp put(claims, _name, nil), do: claims
  defp put(claims, name, value), do: Map.put(claims, name, value)

  defp b64(data), do: Base.url_encode64(data, padding: false)

  defimpl Inspect do
    def inspect(key, _opts),
      do: "#EsuissRelay.DpopKey<" <> Base.url_encode64(key.public, padding: false) <> ">"
  end
end
