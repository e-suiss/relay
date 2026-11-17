defmodule Relay.Agents.MessageSigner do
  @moduledoc """
  The signature of an agent message envelope (AG-40, AG-41, TN-63). Every tenant environment has one Ed25519 key pair for the messages of its mailboxes, generated inside the key store under a label of its own the first time it is needed: the private key never leaves the key store and every signature is made there. The public key is read from the key store and published with the mailbox.

  The signature follows the webhook profile Relay signs its events with: the signed content is `<id>.<timestamp>.<envelope>` over the bytes of the envelope as delivered, `id` being the record's durable handle and `timestamp` the Unix second of signing, and the token is `v1a,` with the base64 of the signature. The public key is published as `whpk_` with its base64. Both functions reach the key store, so neither runs inside a transaction.
  """

  alias Relay.Error

  @label_prefix "relay-agent-message-"

  @type signed :: %{timestamp: non_neg_integer(), signature: String.t()}

  # TN-63
  @doc "The key store label of the message key of a tenant environment."
  @spec label(Relay.Scope.t()) :: Relay.Keys.label()
  def label(%Relay.Scope{tenant_id: tenant_id, environment: environment}),
    do: @label_prefix <> Relay.Id.to_string(tenant_id) <> "-" <> Atom.to_string(environment)

  # AG-40
  # TN-63
  @doc "The public key of the scope's message key; the key pair is generated when the scope has none."
  @spec public_key(Relay.Scope.t()) :: {:ok, <<_::256>>} | {:error, Error.t()}
  def public_key(%Relay.Scope{} = scope) do
    label = label(scope)

    case read(label) do
      {:error, %Error{code: :key_not_found}} -> generate(label)
      other -> other
    end
  end

  defp read(label) do
    case Relay.Keys.public_key(:ed25519, label) do
      {:ok, <<_::256>> = key} -> {:ok, key}
      {:ok, _other} -> {:error, Error.new(:key_refused, "the message key is no Ed25519 key")}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp generate(label) do
    <<id::binary-16, _rest::binary>> = :crypto.hash(:sha256, label)

    case Relay.Keys.generate_key_pair(:ed25519, label, id) do
      {:ok, <<_::256>> = key} -> {:ok, key}
      {:error, %Error{code: :key_exists}} -> read(label)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  # AG-40
  @doc "The published text form of a message key."
  @spec key_text(<<_::256>>) :: String.t()
  def key_text(<<_::256>> = public_key), do: "whpk_" <> Base.encode64(public_key)

  # AG-40
  @doc "The content a signature covers: `<id>.<timestamp>.<envelope>`."
  @spec signed_content(String.t(), non_neg_integer(), binary()) :: binary()
  def signed_content(id, timestamp, envelope)
      when is_binary(id) and is_integer(timestamp) and is_binary(envelope),
      do: id <> "." <> Integer.to_string(timestamp) <> "." <> envelope

  # AG-40
  # AG-41
  @doc "Signs an envelope with the scope's message key at the current time."
  @spec sign(Relay.Scope.t(), String.t(), binary()) :: {:ok, signed()} | {:error, Error.t()}
  def sign(%Relay.Scope{} = scope, id, envelope) when is_binary(id) and is_binary(envelope) do
    timestamp = DateTime.to_unix(Relay.Clock.utc_now())

    case Relay.Keys.sign(:ed25519, label(scope), signed_content(id, timestamp, envelope)) do
      {:ok, <<_::512>> = signature} ->
        {:ok, %{timestamp: timestamp, signature: "v1a," <> Base.encode64(signature)}}

      {:ok, _other} ->
        {:error, Error.new(:key_refused, "the key store returned no Ed25519 signature")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end
end
