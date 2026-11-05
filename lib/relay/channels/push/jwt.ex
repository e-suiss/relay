defmodule Relay.Channels.Push.Jwt do
  @moduledoc """
  Compact JSON Web Tokens for push providers (APNs provider token, VAPID, FCM assertion), signed in the key store: the private key never enters application memory and the token only carries the signature the key store returns (TN-28). ES256 signatures are the fixed 64-byte `R‖S` form; RS256 signatures are RSASSA-PKCS1-v1_5 with SHA-256. Header and claims are encoded in the order given, so a token is reproducible from its inputs.
  """

  alias Relay.Error

  @typedoc "Signs a message in the key store; `Relay.Keys.sign/3` by default."
  @type signer :: (Relay.Keys.alg(), Relay.Keys.label(), binary() ->
                     {:ok, binary()} | {:error, Error.t()})

  @typedoc "Ordered JSON members."
  @type members :: [{String.t(), term()}]

  @algs %{es256: "ES256", rs256: "RS256"}

  # TN-28
  # TN-35
  @doc "Signs a token over `header` and `claims` with the key store key `label`; the `alg` header member is set from `alg` and comes first."
  @spec sign(:es256 | :rs256, Relay.Keys.label(), members(), members(), signer()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def sign(alg, label, header, claims, signer \\ &Relay.Keys.sign/3)
      when is_map_key(@algs, alg) and is_binary(label) and is_function(signer, 3) do
    header = [{"alg", Map.fetch!(@algs, alg)} | List.keydelete(header, "alg", 0)]
    input = segment(header) <> "." <> segment(claims)

    case signer.(alg, label, input) do
      {:ok, signature} when is_binary(signature) ->
        if signature?(alg, signature),
          do: {:ok, input <> "." <> encode64(signature)},
          else: malformed()

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @doc "Base64url without padding (RFC 7515)."
  @spec encode64(binary()) :: String.t()
  def encode64(bytes) when is_binary(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc "Decodes base64url with or without padding."
  @spec decode64(String.t()) :: {:ok, binary()} | :error
  def decode64(text) when is_binary(text),
    do: text |> String.trim_trailing("=") |> Base.url_decode64(padding: false)

  @doc "Decodes the claims of a compact token without verifying it."
  @spec peek_claims(String.t()) :: {:ok, map()} | :error
  def peek_claims(token) when is_binary(token) do
    with [_header, claims, _signature] <- String.split(token, "."),
         {:ok, json} <- decode64(claims),
         {:ok, %{} = map} <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  defp segment(members), do: members |> Jason.OrderedObject.new() |> Jason.encode!() |> encode64()

  defp malformed,
    do: {:error, Error.new(:push_signature_invalid, "the key store signature is malformed")}

  defp signature?(:es256, signature), do: byte_size(signature) == 64
  defp signature?(:rs256, signature), do: byte_size(signature) >= 256
end
