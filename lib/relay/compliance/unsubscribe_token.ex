defmodule Relay.Compliance.UnsubscribeToken do
  @moduledoc """
  The one-click unsubscribe token (PC-35, TN-35): what the `List-Unsubscribe` URI and the footer link of a bulk e-mail carry. It names the tenant environment, the recipient, the category and the channel of the message, the brand it was sent for and its own identifier, and it states its purpose (`unsubscribe`) and its scope (`category`) itself, so it is never read as anything else.

  The token is two base64url parts joined by a dot: the fields in a fixed binary layout, and their ES256 signature made in the key store (TN-63) over the fields behind a domain separation prefix. The label of the signing key is one of the fields. `config :relay, Relay.Compliance, unsubscribe_key: label` names the key that signs (`unsubscribe-link`), and `unsubscribe_verify_keys: [label]` the earlier keys whose links still work; a token under any other label is invalid.

  A token has no expiry: an unsubscribe link works for as long as its key verifies (PC-39). It is revocable by its identifier, which the caller checks against the revocation list (`Relay.Compliance.Refusals`).
  """

  alias Relay.Scope

  @version 1
  @purpose 1
  @category_scope 1
  @prefix "relay.unsubscribe.v1:"
  @environments %{live: 0, test: 1}
  @max_token 1_024

  @type claims :: %{
          scope: Scope.t(),
          id: Relay.Id.t(),
          recipient_id: Relay.Id.t(),
          category: String.t(),
          channel: String.t(),
          brand_subtenant_id: Relay.Id.t() | nil
        }

  # PC-35
  # TN-35
  # TN-63
  @doc "Signs a token for `claims`. Reaches the key store, so it never runs inside a transaction."
  @spec issue(claims()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def issue(%{scope: %Scope{} = scope, id: <<_::128>>, recipient_id: <<_::128>>} = claims) do
    label = signing_key()

    with {:ok, fields} <- encode(scope, claims, label),
         {:ok, <<_::512>> = signature} <- Relay.Keys.sign(:es256, label, @prefix <> fields) do
      {:ok, part(fields) <> "." <> part(signature)}
    else
      _failed -> {:error, Relay.Error.new(:service_unavailable, "the link is not signed")}
    end
  end

  # PC-35
  # TN-35
  @doc "Verifies a token's signature, purpose and scope and returns its claims; `:unavailable` when the key store cannot be asked."
  @spec verify(term()) :: {:ok, claims()} | {:error, :invalid | :unavailable}
  def verify(token) when is_binary(token) and byte_size(token) <= @max_token do
    with [fields_part, signature_part] <- String.split(token, "."),
         {:ok, fields} <- Base.url_decode64(fields_part, padding: false),
         {:ok, <<r::256, s::256>>} <- Base.url_decode64(signature_part, padding: false),
         {:ok, claims, label} <- decode(fields),
         true <- label in accepted_keys() do
      signed(label, fields, {r, s}, claims)
    else
      _other -> {:error, :invalid}
    end
  end

  def verify(_token), do: {:error, :invalid}

  defp signed(label, fields, {r, s}, claims) do
    case Relay.Keys.public_key(:es256, label) do
      {:ok, <<4, _::binary-size(64)>> = point} ->
        der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

        if :crypto.verify(:ecdsa, :sha256, @prefix <> fields, der, [point, :secp256r1]),
          do: {:ok, claims},
          else: {:error, :invalid}

      _unreadable ->
        {:error, :unavailable}
    end
  end

  defp encode(scope, claims, label) do
    brand = Map.get(claims, :brand_subtenant_id) || <<>>
    channel = Map.get(claims, :channel)
    category = Map.get(claims, :category)

    if short?(channel) and short?(category) and short?(label) and byte_size(brand) in [0, 16] do
      {:ok,
       <<@version, @purpose, @category_scope, Map.fetch!(@environments, scope.environment),
         scope.tenant_id::binary-16, claims.recipient_id::binary-16, claims.id::binary-16,
         byte_size(brand), brand::binary, byte_size(channel), channel::binary,
         byte_size(category), category::binary, byte_size(label), label::binary>>}
    else
      :error
    end
  end

  defp short?(value), do: is_binary(value) and byte_size(value) in 1..128

  defp decode(
         <<@version, @purpose, @category_scope, environment, tenant_id::binary-16,
           recipient_id::binary-16, id::binary-16, brand_size, brand::binary-size(brand_size),
           channel_size, channel::binary-size(channel_size), category_size,
           category::binary-size(category_size), label_size, label::binary-size(label_size)>>
       )
       when brand_size in [0, 16] and environment in [0, 1] do
    environment = if environment == 0, do: :live, else: :test

    with {:ok, scope} <- Scope.new(tenant_id, environment) do
      claims = %{
        scope: scope,
        id: id,
        recipient_id: recipient_id,
        category: category,
        channel: channel,
        brand_subtenant_id: if(brand_size == 16, do: brand)
      }

      {:ok, claims, label}
    end
  end

  defp decode(_fields), do: :error

  defp part(binary), do: Base.url_encode64(binary, padding: false)

  defp signing_key, do: Relay.Compliance.config(:unsubscribe_key, "unsubscribe-link")

  defp accepted_keys,
    do: [signing_key() | Relay.Compliance.config(:unsubscribe_verify_keys, [])]
end
