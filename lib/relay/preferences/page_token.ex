defmodule Relay.Preferences.PageToken do
  @moduledoc """
  The token of the hosted preference page (X-51, PC-18): what the link of the page carries. It names the tenant environment, the subscriber and its own identifier and the instant it expires, and it states its purpose (the preference page) itself, so it opens nothing else: neither an unsubscribe link nor any API call accepts it, and it opens the page of no other subscriber.

  The token is two base64url parts joined by a dot: the fields in a fixed binary layout, and their ES256 signature made in the key store (TN-63) over the fields behind a domain separation prefix of its own. The label of the signing key is one of the fields. `config :relay, Relay.Preferences, page_link_key: label` names the key that signs (`preference-link`) and `page_link_verify_keys: [label]` the earlier keys whose links still work; a token under any other label is invalid. A token expires `preference_page_link_lifetime_seconds` (`x-relay-limits`) after it was issued.
  """

  alias Relay.Scope

  @version 1
  @purpose 2
  @prefix "relay.preference_page.v1:"
  @environments %{live: 0, test: 1}
  @max_token 1_024
  @lifetime_s Relay.Limits.fetch!(["preference_page_link_lifetime_seconds"])

  @type claims :: %{
          scope: Scope.t(),
          id: Relay.Id.t(),
          recipient_id: Relay.Id.t(),
          expires_at: DateTime.t()
        }

  # X-51
  @doc "The lifetime of a token in seconds, from the contract."
  @spec lifetime_s() :: pos_integer()
  def lifetime_s, do: @lifetime_s

  # X-51
  # PC-18
  # TN-63
  @doc "Signs a new token for a subscriber of `scope`, expiring after the contract's lifetime. Reaches the key store, so it never runs inside a transaction."
  @spec issue(Scope.t(), Relay.Id.t()) :: {:ok, String.t(), claims()} | {:error, Relay.Error.t()}
  def issue(%Scope{} = scope, <<_::128>> = recipient_id) do
    label = signing_key()
    now = DateTime.truncate(Relay.Clock.utc_now(), :second)

    claims = %{
      scope: scope,
      id: Relay.Id.generate(),
      recipient_id: recipient_id,
      expires_at: DateTime.add(now, @lifetime_s, :second)
    }

    with {:ok, fields} <- encode(claims, label),
         {:ok, <<_::512>> = signature} <- Relay.Keys.sign(:es256, label, @prefix <> fields) do
      {:ok, part(fields) <> "." <> part(signature), claims}
    else
      _failed -> {:error, Relay.Error.new(:service_unavailable, "the link is not signed")}
    end
  end

  # X-51
  # PC-18
  @doc "Verifies a token's signature and purpose and returns its claims: `:expired` once its instant has passed, `:invalid` for anything else that does not verify, `:unavailable` when the key store cannot be asked."
  @spec verify(term()) :: {:ok, claims()} | {:error, :invalid | :expired | :unavailable}
  def verify(token) when is_binary(token) and byte_size(token) <= @max_token do
    with [fields_part, signature_part] <- String.split(token, "."),
         {:ok, fields} <- Base.url_decode64(fields_part, padding: false),
         {:ok, <<r::256, s::256>>} <- Base.url_decode64(signature_part, padding: false),
         {:ok, claims, label} <- decode(fields),
         true <- label in accepted_keys(),
         {:ok, claims} <- signed(label, fields, {r, s}, claims) do
      current(claims)
    else
      {:error, :unavailable} -> {:error, :unavailable}
      _other -> {:error, :invalid}
    end
  end

  def verify(_token), do: {:error, :invalid}

  defp current(claims) do
    if DateTime.compare(Relay.Clock.utc_now(), claims.expires_at) == :lt,
      do: {:ok, claims},
      else: {:error, :expired}
  end

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

  defp encode(%{scope: scope} = claims, label) when byte_size(label) in 1..128 do
    {:ok,
     <<@version, @purpose, Map.fetch!(@environments, scope.environment),
       scope.tenant_id::binary-16, claims.recipient_id::binary-16, claims.id::binary-16,
       DateTime.to_unix(claims.expires_at)::64, byte_size(label), label::binary>>}
  end

  defp encode(_claims, _label), do: :error

  defp decode(
         <<@version, @purpose, environment, tenant_id::binary-16, recipient_id::binary-16,
           id::binary-16, expires_at::64, label_size, label::binary-size(label_size)>>
       )
       when environment in [0, 1] do
    environment = if environment == 0, do: :live, else: :test

    with {:ok, scope} <- Scope.new(tenant_id, environment),
         {:ok, expires_at} <- DateTime.from_unix(expires_at) do
      claims = %{scope: scope, id: id, recipient_id: recipient_id, expires_at: expires_at}
      {:ok, claims, label}
    else
      _invalid -> :error
    end
  end

  defp decode(_fields), do: :error

  defp part(binary), do: Base.url_encode64(binary, padding: false)

  defp signing_key, do: config(:page_link_key, "preference-link")

  defp accepted_keys, do: [signing_key() | config(:page_link_verify_keys, [])]

  defp config(key, default) do
    :relay |> Application.get_env(Relay.Preferences, []) |> Keyword.get(key, default)
  end
end
