defmodule Relay.Access.PortalToken do
  @moduledoc """
  The webhook portal token (WH-47): the short-lived credential of the embeddable webhook portal. A tenant backend mints it for one consumer with its API client credential (`issue/3`), and the portal presents it as `Authorization: Bearer` on the portal operations; `verify/2` accepts nothing else, so an Access token or a subscriber token is never a portal credential, and a portal token is never a subscriber credential.

  The token is a JWS (ES256) of type `relay-webhook-portal+jwt`, signed in the key store under the current subscriber token key, whose label is the `kid` (`Relay.Access.SubscriberTokenKeys`, TN-63); it verifies under the current key or, within its window after a rotation, the previous one. It is valid for the contract's `webhook.portal_token_lifetime_seconds`, names exactly one consumer (`sub`) and one environment (`env`) and carries no scope: the portal operations read and change only that consumer's endpoints and messages. The tenant travels sealed under the region KEK, bound to the environment and the consumer, so the client never sees it and the sealed value opens for no other consumer (TN-25).
  """

  alias Relay.Access.Jose
  alias Relay.Access.SubscriberTokenKeys
  alias Relay.Access.Token
  alias Relay.Scope

  @typ "relay-webhook-portal+jwt"
  @lifetime_s Relay.Limits.fetch!(["webhook", "portal_token_lifetime_seconds"])
  @aad "relay.webhook_portal_token.v1:"

  @type audiences :: %{issuer: String.t(), audience: String.t()}
  @type issued :: %{token: String.t(), expires_at: DateTime.t()}
  @type verified :: %{scope: Scope.t(), consumer_id: Relay.Id.t(), kid: String.t()}

  # WH-47
  @doc "The portal token's lifetime in seconds."
  @spec lifetime_s() :: pos_integer()
  def lifetime_s, do: @lifetime_s

  # WH-47
  # TN-25
  # TN-63
  @doc "Signs a portal token for one consumer of `scope`; the caller has checked that the consumer exists and is active. Reaches the key store, so it never runs inside a transaction."
  @spec issue(Scope.t(), Relay.Id.t(), audiences()) :: {:ok, issued()} | {:error, Relay.Error.t()}
  def issue(%Scope{} = scope, <<_::128>> = consumer_id, audiences) do
    environment = Relay.Environment.dump(scope.environment)
    consumer = Relay.ExternalId.encode("whc", consumer_id)
    now = now()

    with {:ok, label} <- SubscriberTokenKeys.current_label(),
         {:ok, kek} <- Relay.Keys.kek_label(),
         {:ok, sealed} <- seal(kek, environment, consumer, scope.tenant_id) do
      header = %{"alg" => "ES256", "typ" => @typ, "kid" => label}

      claims = %{
        "iss" => audiences.issuer,
        "aud" => audiences.audience,
        "sub" => consumer,
        "env" => environment,
        "iat" => now,
        "nbf" => now,
        "exp" => now + @lifetime_s,
        "jti" => Jose.encode(Relay.Random.bytes(16)),
        "ctx" => Jose.encode(sealed)
      }

      input = Jose.encode(Jason.encode!(header)) <> "." <> Jose.encode(Jason.encode!(claims))
      sign(label, input, DateTime.from_unix!(now + @lifetime_s))
    else
      {:error, _error} -> unavailable()
    end
  end

  defp seal(kek, environment, consumer, tenant_id) do
    secret = Relay.Redacted.wrap(tenant_id <> Relay.Random.bytes(16))
    Relay.Keys.wrap(kek, aad(environment, consumer), secret)
  end

  defp aad(environment, consumer), do: @aad <> environment <> ":" <> consumer

  defp sign(label, input, expires_at) do
    case Relay.Keys.sign(:es256, label, input) do
      {:ok, <<_::512>> = signature} ->
        {:ok, %{token: input <> "." <> Jose.encode(signature), expires_at: expires_at}}

      _failed ->
        unavailable()
    end
  end

  # WH-47
  # E-25
  # API-76 (2)
  @doc "Verifies a portal token for `audiences` and returns its scope, its consumer and its signing key label; any other token is `auth_invalid_token`. Whether the consumer still exists and is active is the caller's check."
  @spec verify(String.t(), audiences()) :: {:ok, verified()} | {:error, Relay.Error.t()}
  def verify(token, audiences) when is_binary(token) do
    with {:ok, %{"kid" => label, "alg" => "ES256", "typ" => @typ}} when is_binary(label) <-
           Jose.peek_header(token),
         {:ok, true} <- SubscriberTokenKeys.accepted?(label),
         {:ok, point} <- Relay.Keys.public_key(:es256, label),
         key = %{kid: label, alg: "ES256", type: :es256, public: point},
         expectation = expectation(audiences),
         {:ok, claims} <- Token.verify(token, [key], expectation),
         {:ok, consumer_id} <- Relay.ExternalId.decode(claims["sub"], ["whc"]),
         {:ok, scope} <- unseal(claims) do
      {:ok, %{scope: scope, consumer_id: consumer_id, kid: label}}
    else
      {:error, %Relay.Error{code: code} = error}
      when code in [:auth_expired_token, :service_unavailable] ->
        {:error, error}

      _other ->
        {:error, Relay.Error.new(:auth_invalid_token, "not a Relay webhook portal token")}
    end
  end

  defp expectation(audiences),
    do: %{issuer: audiences.issuer, audience: audiences.audience, now: now(), typ: @typ}

  defp unseal(%{"env" => environment, "sub" => consumer, "ctx" => ctx})
       when environment in ["live", "test"] and is_binary(ctx) do
    with {:ok, sealed} <- Jose.decode(ctx),
         {:ok, kek} <- Relay.Keys.kek_label(),
         {:ok, secret} <- Relay.Keys.unwrap(kek, aad(environment, consumer), sealed),
         <<tenant_id::binary-16, _salt::binary-16>> <- Relay.Redacted.expose(secret) do
      Scope.new(tenant_id, environment)
    end
  end

  defp unseal(_claims), do: :error

  defp unavailable,
    do: {:error, Relay.Error.new(:service_unavailable, "the portal token is not signed")}

  defp now, do: DateTime.to_unix(Relay.Clock.utc_now())
end
