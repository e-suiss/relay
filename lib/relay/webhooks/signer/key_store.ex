defmodule Relay.Webhooks.Signer.KeyStore do
  @moduledoc """
  The signer of a running node (WH-5, TN-32, TN-63). A `v1a` key pair is generated inside the PKCS#11 key store under a label of its own (`Relay.Keys.generate_key_pair/3`): the private key never leaves the key store, in any form, and every signature is made there (`Relay.Keys.sign/3`). The database holds the key's label, sealed under the tenant's data key through the sealer of `Relay.Webhooks`, so destroying the tenant's data key ends the use of the key. A `v1` secret is 32 random bytes sealed the same way; it is opened only in the process that signs, for the one HMAC.
  """

  @behaviour Relay.Webhooks.Signer

  alias Relay.Error
  alias Relay.Redacted
  alias Relay.Webhooks.Profile
  alias Relay.Webhooks.Signer

  @sealer Relay.Webhooks.Live
  @field {"webhook_endpoint_keys", "secret_ct"}
  @secret_bytes 32
  @label_prefix "relay-webhook-"

  # WH-5
  # TN-32
  @impl Signer
  def generate(scope, :v1a) do
    id = Relay.Id.generate()
    label = @label_prefix <> Relay.Id.to_string(id)

    with {:ok, public} <- Relay.Keys.generate_key_pair(:ed25519, label, id),
         {:ok, sealed} <- sealer().seal(scope, @field, Redacted.wrap(label)) do
      {:ok, key(id, "v1a", public, sealed, nil)}
    end
  end

  def generate(scope, :v1) do
    secret = Relay.Random.bytes(@secret_bytes)

    with {:ok, sealed} <- sealer().seal(scope, @field, Redacted.wrap(secret)) do
      {:ok, key(Relay.Id.generate(), "v1", nil, sealed, Redacted.wrap(Signer.secret(secret)))}
    end
  end

  defp key(id, scheme, public, sealed, secret) do
    %{
      id: id,
      scheme: scheme,
      public_key: public,
      secret_ct: sealed.ct,
      secret_key_id: sealed.key_id,
      secret: secret
    }
  end

  # WH-6
  # TN-63
  @impl Signer
  def destroy(<<_::128>> = id),
    do: Relay.Keys.destroy_key_pair(:ed25519, @label_prefix <> Relay.Id.to_string(id))

  # WH-4
  # WH-6
  @impl Signer
  def sign(scope, [_ | _] = keys, content) when is_binary(content) do
    signed =
      Enum.reduce_while(keys, [], fn key, tokens ->
        case token(scope, key, content) do
          {:ok, token} -> {:cont, [token | tokens]}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end)

    case signed do
      {:error, error} -> {:error, error}
      tokens -> {:ok, Enum.reverse(tokens)}
    end
  end

  defp token(scope, %{"secret_ct" => ct, "secret_key_id" => key_id} = key, content)
       when is_binary(ct) do
    with {:ok, secret} <- sealer().open(scope, @field, key_id, ct),
         do: signature(key["scheme"], secret, content)
  end

  defp token(_scope, _key, _content),
    do: {:error, Error.new(:signing_key_retired, "the signing key holds no secret")}

  defp signature("v1a", label, content) do
    with {:ok, signature} <- Relay.Keys.sign(:ed25519, Redacted.expose(label), content),
         do: {:ok, Profile.token(:v1a, signature)}
  end

  defp signature("v1", secret, content),
    do: {:ok, Profile.token(:v1, Relay.Crypto.hmac_sha256(secret, content))}

  defp sealer,
    do: :relay |> Application.get_env(Relay.Webhooks, []) |> Keyword.get(:sealer, @sealer)
end
