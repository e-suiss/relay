defmodule Relay.Agents.PrivacyPass do
  @moduledoc """
  Redemption of a Privacy Pass token of type `0x0002`, Blind RSA with a 2048-bit key (RFC 9577, RFC 9578 §6), by the origin (AG-60, AG-73). Relay is the origin of a first contact: it verifies the token with the issuer's public key and never calls the issuer. Issuance is blind, so a token names nobody and cannot be tied to the request it was issued for.

  A token is 354 bytes: the token type (2 bytes), the client's nonce (32), the SHA-256 digest of the `TokenChallenge` it answers (32), the identifier of the issuer key (32) and the authenticator (256). The key identifier is the SHA-256 digest of the issuer's token key as the issuer directory publishes it: a DER `SubjectPublicKeyInfo` with the RSASSA-PSS algorithm identifier. The authenticator is an RSASSA-PSS signature over the first 98 bytes with SHA-384, MGF1 with SHA-384 and a 48-byte salt.

  The challenge Relay stands for names the issuer and Relay as the only origin and carries no redemption context, so a token is fetched ahead and is spent on any one first contact (`challenge/2`). A token is accepted when its type is `0x0002`, its challenge digest is the digest of that challenge, its key identifier names a key of the issuer and its authenticator verifies under that key. Whether a token was spent before is not decided here: the caller keeps `:digest`, the SHA-256 digest of the token, for the life of the issuer key.
  """

  @token_type 0x0002
  @nonce_bytes 32
  @digest_bytes 32
  @authenticator_bytes 256
  @input_bytes 2 + @nonce_bytes + @digest_bytes + @digest_bytes
  @token_bytes @input_bytes + @authenticator_bytes
  @salt_bytes 48

  @typedoc "An issuer key: the token key as published, its identifier and its RSA modulus and public exponent."
  @type key :: %{
          token_key: binary(),
          key_id: <<_::256>>,
          modulus: binary(),
          exponent: binary()
        }
  @typedoc "What a verified token leaves behind: its digest, kept against a second use, and the identifier of the key that signed it."
  @type spent :: %{digest: <<_::256>>, key_id: <<_::256>>}

  # AG-73
  @doc "The token type Relay accepts: `0x0002`."
  @spec token_type() :: 2
  def token_type, do: @token_type

  # AG-73
  @doc "The length of a token in bytes."
  @spec token_bytes() :: 354
  def token_bytes, do: @token_bytes

  # AG-60
  # AG-73
  @doc "The `TokenChallenge` of RFC 9577 §2.1.1 for an issuer name and an origin name, without a redemption context."
  @spec challenge(String.t(), String.t()) :: binary()
  def challenge(issuer_name, origin)
      when byte_size(issuer_name) in 1..65_535 and byte_size(origin) <= 65_535 do
    <<@token_type::16, byte_size(issuer_name)::16, issuer_name::binary, 0::8,
      byte_size(origin)::16, origin::binary>>
  end

  # AG-73
  @doc "The digest of a `TokenChallenge`, as a token carries it."
  @spec challenge_digest(binary()) :: <<_::256>>
  def challenge_digest(challenge) when is_binary(challenge), do: :crypto.hash(:sha256, challenge)

  # AG-73
  @doc "Reads an issuer token key, a DER `SubjectPublicKeyInfo` of an RSA key with a 2048-bit modulus; `:error` for anything else."
  @spec key(binary()) :: {:ok, key()} | :error
  def key(token_key) when is_binary(token_key) do
    with {:ok, {0x30, info, <<>>}} <- element(token_key),
         {:ok, {0x30, _algorithm, rest}} <- element(info),
         {:ok, {0x03, <<0, public::binary>>, <<>>}} <- element(rest),
         {:ok, {0x30, numbers, <<>>}} <- element(public),
         {:ok, {0x02, modulus, rest}} <- element(numbers),
         {:ok, {0x02, exponent, <<>>}} <- element(rest),
         modulus = unsigned(modulus),
         true <- byte_size(modulus) == @authenticator_bytes do
      {:ok,
       %{
         token_key: token_key,
         key_id: :crypto.hash(:sha256, token_key),
         modulus: modulus,
         exponent: unsigned(exponent)
       }}
    else
      _other -> :error
    end
  end

  def key(_token_key), do: :error

  defp element(<<tag, 0::1, length::7, rest::binary>>), do: content(tag, length, rest)

  defp element(<<tag, 1::1, count::7, rest::binary>>) when count in 1..3 do
    case rest do
      <<length::size(^count)-unit(8), rest::binary>> when length >= 128 ->
        content(tag, length, rest)

      _other ->
        :error
    end
  end

  defp element(_other), do: :error

  defp content(tag, length, rest) do
    case rest do
      <<value::binary-size(^length), rest::binary>> -> {:ok, {tag, value, rest}}
      _short -> :error
    end
  end

  defp unsigned(<<0, rest::binary>>) when rest != <<>>, do: unsigned(rest)
  defp unsigned(number), do: number

  # AG-60
  # AG-73
  @doc "Verifies a token against the digest of the challenge it must answer and the issuer's keys. Returns what to keep of it, or `:error` for a token of another length or type, for another challenge, of an unknown key or with an authenticator that does not verify."
  @spec verify(binary(), <<_::256>>, [key()]) :: {:ok, spent()} | :error
  def verify(
        <<@token_type::16, _nonce::binary-size(@nonce_bytes),
          challenge_digest::binary-size(@digest_bytes), key_id::binary-size(@digest_bytes),
          authenticator::binary-size(@authenticator_bytes)>> = token,
        expected,
        keys
      )
      when byte_size(expected) == @digest_bytes and is_list(keys) do
    input = binary_part(token, 0, @input_bytes)

    with true <- :crypto.hash_equals(challenge_digest, expected),
         %{} = key <- Enum.find(keys, &(&1.key_id == key_id)),
         true <- signed?(input, authenticator, key) do
      {:ok, %{digest: :crypto.hash(:sha256, token), key_id: key_id}}
    else
      _other -> :error
    end
  end

  def verify(_token, _expected, _keys), do: :error

  defp signed?(input, authenticator, %{modulus: modulus, exponent: exponent}) do
    options = [
      rsa_padding: :rsa_pkcs1_pss_padding,
      rsa_pss_saltlen: @salt_bytes,
      rsa_mgf1_md: :sha384
    ]

    :crypto.verify(:rsa, :sha384, input, authenticator, [exponent, modulus], options)
  rescue
    ErlangError -> false
  end
end
