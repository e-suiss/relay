defmodule Relay.Access.SubscriberToken do
  @moduledoc """
  The subscriber token (C-17, E-23, E-24, API-45, TN-25, IN-41, IN-42). `exchange/2` is the only way to obtain one: the client presents its end user's Access access token (RFC 8693); Relay verifies it under the cached Access keys, takes tenant and environment from the Access client registration the token was issued to (never from the request; API-79 (4)), matches the subscriber by the Access pairwise `sub` as its `external_id` and creates an inbox-only subscriber when there is none. When the Access link is not fully established (`:stale` included) no token is issued (E-75).

  The token is a JWS (ES256) signed in the key store under the key named by `config :relay, Relay.Access, subscriber_token_key: label` (TN-63), valid for 15 minutes, with the scopes `inbox:read`, `inbox:write`, `preferences`, `devices:write` and `presence:write` (API-79 (9)). It names the subscriber and the environment; the tenant travels sealed under the region KEK, so the client never sees it (TN-25). `verify/2` accepts only such a token: an Access token is never a subscriber credential (E-25).
  """

  alias Relay.Access.Clients
  alias Relay.Access.Jose
  alias Relay.Access.Link
  alias Relay.Access.Token
  alias Relay.Scope

  @token_type "urn:suiss:relay:token-type:subscriber"
  @scopes ~w(inbox:read inbox:write preferences devices:write presence:write)
  @default ~w(inbox:read inbox:write preferences)
  @lifetime_s 900
  @aad "relay.subscriber_token.v1:"

  @type audiences :: %{issuer: String.t(), audience: String.t(), subject_audience: String.t()}
  @type verified :: %{scope: Scope.t(), subscriber_id: Relay.Id.t(), scopes: [String.t()]}

  @doc "Every subscriber token scope."
  @spec scopes() :: [String.t(), ...]
  def scopes, do: @scopes

  @doc "The subscriber token's lifetime in seconds."
  @spec lifetime_s() :: pos_integer()
  def lifetime_s, do: @lifetime_s

  # E-24
  # API-45
  # API-79 (2)
  # API-79 (4)
  # API-79 (9)
  # TN-25
  @doc "Exchanges an Access access token (the decoded RFC 8693 form) for a subscriber token."
  @spec exchange(map(), audiences()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def exchange(params, audiences) do
    with {:ok, scopes} <- requested(params["scope"]),
         {:ok, keys, issuer} <- live_link(),
         {:ok, claims} <- subject(params["subject_token"], keys, issuer, audiences),
         {:ok, scope} <- registration(claims),
         {:ok, subscriber_id} <- subscriber(scope, claims["sub"]),
         {:ok, token} <- issue(scope, subscriber_id, scopes, audiences) do
      {:ok,
       %{
         "access_token" => token,
         "issued_token_type" => @token_type,
         "token_type" => "Bearer",
         "expires_in" => @lifetime_s,
         "scope" => Enum.join(scopes, " "),
         "subscriber_id" => Relay.ExternalId.encode("sub", subscriber_id),
         "environment" => Relay.Environment.dump(scope.environment)
       }}
    end
  end

  defp requested(nil), do: {:ok, @default}

  defp requested(scope) when is_binary(scope) do
    requested = scope |> String.split(" ", trim: true) |> Enum.uniq()

    if requested != [] and Enum.all?(requested, &(&1 in @scopes)),
      do: {:ok, requested},
      else: {:error, field("/scope", "unsupported_value", "an unknown subscriber scope")}
  end

  # E-75
  defp live_link do
    case Link.current() do
      %{state: :ok, keys: [_ | _] = keys, issuer: issuer} ->
        {:ok, keys, issuer}

      _other ->
        {:error, Relay.Error.new(:service_unavailable, "Access cannot be reached; no token")}
    end
  end

  defp subject(token, keys, issuer, audiences) when is_binary(token) do
    expectation = %{issuer: issuer, audience: audiences.subject_audience, now: now()}

    case Token.verify(token, keys, expectation) do
      {:ok, %{"sub" => sub} = claims} when is_binary(sub) and byte_size(sub) in 1..256 ->
        {:ok, claims}

      {:ok, _claims} ->
        {:error, Relay.Error.new(:auth_invalid_token, "the token names no subject")}

      {:error, :unknown_key} ->
        {:error, Relay.Error.new(:auth_invalid_token, "the token is not signed by Access")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp subject(_token, _keys, _issuer, _audiences),
    do: {:error, field("/subject_token", "required", "an Access token is required")}

  # API-79 (4)
  defp registration(%{"tenant_id" => tenant, "client_id" => client})
       when is_binary(tenant) and is_binary(client) do
    case Clients.resolve(tenant, client) do
      {:ok, %{status: "active", tenant_status: "active"} = resolved} ->
        Scope.new(resolved.tenant_id, resolved.environment)

      {:ok, %{status: "active"}} ->
        {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

      _revoked_or_unknown ->
        {:error, Relay.Error.new(:auth_invalid_token, "the Access client is not registered")}
    end
  end

  defp registration(_claims),
    do: {:error, Relay.Error.new(:auth_invalid_token, "the token names no Access client")}

  # E-24
  # API-21
  defp subscriber(scope, sub) do
    attrs = %{id: Relay.Id.generate(), kind: :subscriber, external_id: sub}

    case Relay.Tenancy.create_recipient(scope, attrs) do
      {:ok, {result, <<_::128>> = id}} when result in [:created, :exists] ->
        {:ok, id}

      {:ok, {:tenant_inactive, _id}} ->
        {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

      _failed ->
        {:error, Relay.Error.new(:service_unavailable, "the subscriber could not be recorded")}
    end
  end

  # IN-42
  # TN-25
  # TN-63
  defp issue(scope, subscriber_id, scopes, audiences) do
    label = key_label()
    environment = Relay.Environment.dump(scope.environment)
    now = now()

    with {:ok, kek} <- Relay.Keys.kek_label(),
         {:ok, sealed} <- seal(kek, environment, scope.tenant_id) do
      header = %{"alg" => "ES256", "typ" => "relay-subscriber+jwt", "kid" => label}

      claims = %{
        "iss" => audiences.issuer,
        "aud" => audiences.audience,
        "sub" => Relay.ExternalId.encode("sub", subscriber_id),
        "env" => environment,
        "scope" => Enum.join(scopes, " "),
        "iat" => now,
        "nbf" => now,
        "exp" => now + @lifetime_s,
        "jti" => Jose.encode(Relay.Random.bytes(16)),
        "ctx" => Jose.encode(sealed)
      }

      input = Jose.encode(Jason.encode!(header)) <> "." <> Jose.encode(Jason.encode!(claims))
      sign(label, input)
    else
      {:error, _error} -> unavailable()
    end
  end

  defp seal(kek, environment, tenant_id) do
    secret = Relay.Redacted.wrap(tenant_id <> Relay.Random.bytes(16))
    Relay.Keys.wrap(kek, @aad <> environment, secret)
  end

  defp sign(label, input) do
    case Relay.Keys.sign(:es256, label, input) do
      {:ok, <<_::512>> = signature} -> {:ok, input <> "." <> Jose.encode(signature)}
      _failed -> unavailable()
    end
  end

  # API-45
  # E-25
  # IN-41
  # API-76 (2)
  @doc "Verifies a subscriber token for `audiences` and returns its scope, subscriber and scopes; an Access token or any other token is `auth_invalid_token`."
  @spec verify(String.t(), audiences()) :: {:ok, verified()} | {:error, Relay.Error.t()}
  def verify(token, audiences) when is_binary(token) do
    label = key_label()

    with {:ok, %{"kid" => ^label, "alg" => "ES256"}} <- Jose.peek_header(token),
         {:ok, point} <- Relay.Keys.public_key(:es256, label),
         key = %{kid: label, alg: "ES256", type: :es256, public: point},
         expectation = %{issuer: audiences.issuer, audience: audiences.audience, now: now()},
         {:ok, claims} <- Token.verify(token, [key], expectation),
         {:ok, scope} <- unseal(claims),
         {:ok, subscriber_id} <- Relay.ExternalId.decode(claims["sub"], ["sub"]) do
      scopes = claims["scope"] |> to_string() |> String.split(" ", trim: true)
      {:ok, %{scope: scope, subscriber_id: subscriber_id, scopes: scopes}}
    else
      {:error, %Relay.Error{code: :auth_expired_token} = error} -> {:error, error}
      _other -> {:error, Relay.Error.new(:auth_invalid_token, "not a Relay subscriber token")}
    end
  end

  defp unseal(%{"env" => environment, "ctx" => ctx}) when environment in ["live", "test"] do
    with {:ok, sealed} <- Jose.decode(ctx),
         {:ok, kek} <- Relay.Keys.kek_label(),
         {:ok, secret} <- Relay.Keys.unwrap(kek, @aad <> environment, sealed),
         <<tenant_id::binary-16, _salt::binary-16>> <- Relay.Redacted.expose(secret) do
      Scope.new(tenant_id, environment)
    end
  end

  defp unseal(_claims), do: :error

  defp key_label,
    do: Keyword.get(Relay.Access.config(), :subscriber_token_key, "subscriber-token")

  defp field(pointer, code, detail) do
    Relay.Error.new(:validation_failed, detail, %{
      errors: [%{pointer: pointer, code: code, detail: detail}]
    })
  end

  defp unavailable,
    do: {:error, Relay.Error.new(:service_unavailable, "the subscriber token could not be signed")}

  defp now, do: DateTime.to_unix(Relay.Clock.utc_now())
end
