defmodule Relay.Access.Jose do
  @moduledoc """
  JSON Web Key and compact JSON Web Signature primitives of the Access link. Only the allowed algorithms verify: EdDSA over Ed25519, ES256 over P-256 and PS256 over RSA keys of at least 2048 bits (S-68). An unsigned token, any other algorithm and a key whose `alg` or `use` does not fit are refused. A key set that carries private key members is refused as a whole, and the stored key set keeps only the public members.
  """

  @algorithms ["EdDSA", "ES256", "PS256"]
  @private ["d", "p", "q", "dp", "dq", "qi", "k", "oth"]
  @public ["kty", "kid", "use", "alg", "crv", "x", "y", "n", "e"]
  @pss [rsa_padding: :rsa_pkcs1_pss_padding, rsa_pss_saltlen: 32]

  @type key :: %{
          kid: String.t() | nil,
          alg: String.t(),
          type: :ed25519 | :es256 | :ps256,
          public: binary() | {:RSAPublicKey, pos_integer(), pos_integer()}
        }

  @type failure :: :malformed | :algorithm | :unknown_key | :signature

  # API-71
  @doc "The signature algorithms a token may use."
  @spec algorithms() :: [String.t(), ...]
  def algorithms, do: @algorithms

  # API-71
  # E-78
  @doc "Reads a JSON Web Key Set: its usable public signature keys and the set reduced to public members; a set with private members or without any usable key is refused."
  @spec public_keys(term()) :: {:ok, [key(), ...], map()} | {:error, Relay.Error.t()}
  def public_keys(%{"keys" => jwks}) when is_list(jwks) do
    if Enum.any?(jwks, &private?/1),
      do: invalid("the key set carries private key members"),
      else: usable(jwks, Enum.flat_map(jwks, &key/1))
  end

  def public_keys(_jwks), do: invalid("not a JSON Web Key Set")

  defp usable(_jwks, []), do: invalid("the key set has no usable signature key")

  defp usable(jwks, keys),
    do: {:ok, keys, %{"keys" => Enum.map(jwks, &Map.take(&1, @public))}}

  defp private?(jwk) when is_map(jwk), do: Enum.any?(@private, &Map.has_key?(jwk, &1))
  defp private?(_jwk), do: true

  defp key(%{"use" => usage}) when usage != "sig", do: []

  defp key(%{"kty" => "OKP", "crv" => "Ed25519", "x" => x} = jwk) do
    case decode(x) do
      {:ok, <<_::256>> = public} -> fit(jwk, "EdDSA", :ed25519, public)
      _ -> []
    end
  end

  defp key(%{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y} = jwk) do
    case {decode(x), decode(y)} do
      {{:ok, <<_::256>> = px}, {:ok, <<_::256>> = py}} ->
        fit(jwk, "ES256", :es256, <<4, px::binary, py::binary>>)

      _ ->
        []
    end
  end

  defp key(%{"kty" => "RSA", "n" => n, "e" => e} = jwk) do
    with {:ok, modulus} <- decode(n),
         {:ok, exponent} <- decode(e),
         true <- bit_size(modulus) >= 2048 do
      rsa = {:RSAPublicKey, :binary.decode_unsigned(modulus), :binary.decode_unsigned(exponent)}
      fit(jwk, "PS256", :ps256, rsa)
    else
      _ -> []
    end
  end

  defp key(_jwk), do: []

  defp fit(jwk, alg, type, public) do
    case Map.get(jwk, "alg", alg) do
      ^alg -> [%{kid: kid(jwk), alg: alg, type: type, public: public}]
      _other -> []
    end
  end

  defp kid(%{"kid" => kid}) when is_binary(kid), do: kid
  defp kid(_jwk), do: nil

  # API-71
  # API-47
  @doc "Verifies a compact JWS against `keys` and returns its decoded header and claims; the key is chosen by `kid` and must fit the header's algorithm."
  @spec verify(String.t(), [key()]) :: {:ok, map(), map()} | {:error, failure()}
  def verify(token, keys) when is_binary(token) and is_list(keys) do
    with {:ok, encoded_header, encoded_claims, signature} <- split(token),
         {:ok, header} <- json(encoded_header),
         {:ok, alg} <- algorithm(header),
         {:ok, claims} <- json(encoded_claims),
         {:ok, candidates} <- candidates(keys, header, alg) do
      input = encoded_header <> "." <> encoded_claims

      if Enum.any?(candidates, &valid?(&1, input, signature)),
        do: {:ok, header, claims},
        else: {:error, :signature}
    end
  end

  # API-71
  @doc "Reads the header of a compact JWS without verifying it."
  @spec peek_header(String.t()) :: {:ok, map()} | {:error, :malformed}
  def peek_header(token) when is_binary(token) do
    with {:ok, encoded_header, _claims, _signature} <- split(token),
         do: json(encoded_header)
  end

  defp split(token) do
    with [header, claims, encoded] <- String.split(token, "."),
         {:ok, signature} <- decode(encoded) do
      {:ok, header, claims, signature}
    else
      _ -> {:error, :malformed}
    end
  end

  defp json(encoded) do
    with {:ok, raw} <- decode(encoded),
         {:ok, %{} = map} <- Jason.decode(raw) do
      {:ok, map}
    else
      _ -> {:error, :malformed}
    end
  end

  defp algorithm(%{"alg" => alg}) when alg in @algorithms, do: {:ok, alg}
  defp algorithm(_header), do: {:error, :algorithm}

  defp candidates(keys, header, alg) do
    kid = Map.get(header, "kid")

    case Enum.filter(keys, &(&1.alg == alg and (is_nil(kid) or &1.kid == kid))) do
      [] -> {:error, :unknown_key}
      found -> {:ok, found}
    end
  end

  # API-71
  @doc "Whether `signature` is a valid signature of `input` under `key`; malformed input is not valid."
  @spec valid?(key(), binary(), binary()) :: boolean()
  def valid?(key, input, signature) do
    check(key, input, signature)
  rescue
    _exception -> false
  end

  defp check(%{type: :ed25519, public: public}, input, <<_::512>> = signature),
    do: :crypto.verify(:eddsa, :none, input, signature, [public, :ed25519])

  defp check(%{type: :es256, public: point}, input, <<r::256, s::256>>) do
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    :crypto.verify(:ecdsa, :sha256, input, der, [point, :secp256r1])
  end

  defp check(%{type: :ps256, public: rsa}, input, signature),
    do: :public_key.verify(input, :sha256, signature, rsa, @pss)

  defp check(_key, _input, _signature), do: false

  @doc "Decodes unpadded base64url."
  @spec decode(term()) :: {:ok, binary()} | :error
  def decode(text) when is_binary(text), do: Base.url_decode64(text, padding: false)
  def decode(_text), do: :error

  @doc "Encodes unpadded base64url."
  @spec encode(binary()) :: String.t()
  def encode(bytes) when is_binary(bytes), do: Base.url_encode64(bytes, padding: false)

  defp invalid(message), do: {:error, Relay.Error.new(:access_keys_invalid, message)}
end
