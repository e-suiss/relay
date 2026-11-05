defmodule Relay.Channels.Email.Verp do
  @moduledoc """
  The VERP return path of an outgoing e-mail (CH-38): `b-<token>@<return path domain>`, where the token is the lowercase, unpadded base32 of the delivery's 16-byte identifier followed by a 10-byte tag. The tag is the start of an HMAC-SHA256, computed by the caller's key function, over the identifier and the return path domain, so a bounce cannot name a delivery it was not sent for. The local part is 44 characters and survives case folding.

  The key function takes the message and returns `{:ok, mac}`; `key_function/1` builds one that computes the HMAC inside the key store (`Relay.Keys.hmac_sha256/2`).
  """

  alias Relay.Error

  @prefix "b-"
  @tag_size 10
  @context "relay.verp.v1"

  @type mac :: (binary() -> {:ok, <<_::256>>} | {:error, Error.t()})

  @doc "A key function that computes the tag inside the key store under the secret key `label`."
  @spec key_function(Relay.Keys.label()) :: mac()
  def key_function(label) when is_binary(label) and label != "" do
    fn message -> Relay.Keys.hmac_sha256(label, Relay.Redacted.wrap(message)) end
  end

  # CH-38
  @doc "The VERP return path of a delivery under a return path domain."
  @spec encode(<<_::128>>, String.t(), mac()) :: {:ok, String.t()} | {:error, Error.t()}
  def encode(<<_::128>> = delivery_id, domain, mac) when is_binary(domain) do
    domain = String.downcase(domain, :ascii)

    with {:ok, tag} <- tag(delivery_id, domain, mac) do
      token = Base.encode32(delivery_id <> tag, case: :lower, padding: false)
      {:ok, @prefix <> token <> "@" <> domain}
    end
  end

  # CH-38
  # CH-39
  @doc "The delivery identifier a VERP return path names; `:not_verp` when the address is not one and `:forged` when its tag does not match."
  @spec decode(String.t(), mac()) ::
          {:ok, <<_::128>>} | {:error, :not_verp | :forged | Error.t()}
  def decode(address, mac) when is_binary(address) do
    with {:ok, local, domain} <- split(address),
         {:ok, <<delivery_id::binary-16, tag::binary-size(@tag_size)>>} <- token(local),
         {:ok, expected} <- tag(delivery_id, domain, mac) do
      if Relay.Crypto.secure_compare(tag, expected),
        do: {:ok, delivery_id},
        else: {:error, :forged}
    else
      {:ok, _other} -> {:error, :not_verp}
      {:error, _reason} = error -> error
    end
  end

  defp split(address) do
    address = address |> String.trim() |> String.trim_leading("<") |> String.trim_trailing(">")

    case String.split(address, "@") do
      [local, domain] when domain != "" -> {:ok, String.downcase(local), String.downcase(domain)}
      _other -> {:error, :not_verp}
    end
  end

  defp token(@prefix <> token) do
    case Base.decode32(token, case: :lower, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :not_verp}
    end
  end

  defp token(_local), do: {:error, :not_verp}

  defp tag(delivery_id, domain, mac) do
    case mac.(Relay.Canonical.encode!([@context, {:bytes, delivery_id}, domain])) do
      {:ok, <<tag::binary-size(@tag_size), _rest::binary>>} -> {:ok, tag}
      {:error, %Error{}} = error -> error
    end
  end
end
