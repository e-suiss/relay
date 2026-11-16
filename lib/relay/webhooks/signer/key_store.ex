defmodule Relay.Webhooks.Signer.KeyStore do
  @moduledoc """
  The signer of a running node (WH-5, TN-32, TN-63). A `v1a` key pair is generated inside the PKCS#11 key store (`Relay.Keys.generate_wrapped_key/1`): its private key comes out only wrapped under the installation's webhook wrapping key (`Relay.Keys.webhook_wrap_label/0`), and to sign it is unwrapped inside the key store, used there and destroyed (`Relay.Keys.sign_wrapped/3`). The wrapped key is then sealed under the tenant's data key through the sealer of `Relay.Webhooks`, so the database holds it encrypted twice and destroying the tenant's data key ends the key. A `v1` secret is 32 random bytes sealed the same way; it is opened only in the process that signs, for the one HMAC.
  """

  @behaviour Relay.Webhooks.Signer

  alias Relay.Error
  alias Relay.Redacted
  alias Relay.Webhooks.Signer

  @sealer Relay.Webhooks.Live
  @field {"webhook_endpoint_keys", "secret_ct"}
  @secret_bytes 32

  # WH-5
  # TN-32
  @impl Signer
  def generate(scope, :v1a) do
    with {:ok, label} <- Relay.Keys.webhook_wrap_label(),
         {:ok, %{wrapped: wrapped, public_key: public}} <- Relay.Keys.generate_wrapped_key(label),
         {:ok, sealed} <- sealer().seal(scope, @field, Redacted.wrap(wrapped)) do
      {:ok, key("v1a", public, sealed, nil)}
    end
  end

  def generate(scope, :v1) do
    secret = Relay.Random.bytes(@secret_bytes)

    with {:ok, sealed} <- sealer().seal(scope, @field, Redacted.wrap(secret)) do
      {:ok, key("v1", nil, sealed, Redacted.wrap(Signer.secret(secret)))}
    end
  end

  defp key(scheme, public, sealed, secret) do
    %{
      id: Relay.Id.generate(),
      scheme: scheme,
      public_key: public,
      secret_ct: sealed.ct,
      secret_key_id: sealed.key_id,
      secret: secret
    }
  end

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

  defp signature("v1a", wrapped, content) do
    with {:ok, label} <- Relay.Keys.webhook_wrap_label(),
         {:ok, signature} <- Relay.Keys.sign_wrapped(label, Redacted.expose(wrapped), content) do
      {:ok, Signer.token(:v1a, signature)}
    end
  end

  defp signature("v1", secret, content),
    do: {:ok, Signer.token(:v1, Relay.Crypto.hmac_sha256(secret, content))}

  defp sealer,
    do: :relay |> Application.get_env(Relay.Webhooks, []) |> Keyword.get(:sealer, @sealer)
end
