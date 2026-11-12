defmodule RelayWeb.Realtime.Authorization do
  @moduledoc """
  Who may hold a realtime connection, checked on connect and again whenever the authorization may have changed (IN-33, INV-42, TN-10): a Relay subscriber token that verifies (an Access token never does, E-25; a suspended subscriber's token no longer does, TN-73), carries `inbox:read` (IN-32) and belongs to an active tenant. The grant names the token's scope, subscriber, scopes and expiry; the client never names a topic, a tenant or a subscriber.

  A connection listens on `topics/1` for the events that can withdraw a grant (a subscriber suspension in its tenant environment, an API client or tenant status change, a rotation or retirement of the subscriber token keys, IN-51) and checks its token again when one fires.
  """

  alias Relay.Api.Tenant
  alias Relay.Operators.SubscriberSuspension
  alias RelayWeb.Auth.Subscriber

  @bearer ~r/\A[Bb]earer +([A-Za-z0-9\-._~+\/]+=*)\z/

  @type grant :: %{
          scope: Relay.Scope.t(),
          subscriber_id: Relay.Id.t(),
          scopes: [String.t()],
          expires_at: integer()
        }

  # IN-32
  # IN-33
  # INV-42
  @doc "Checks a subscriber token for a realtime connection and returns its grant."
  @spec authorize(String.t() | nil) :: {:ok, grant()} | {:error, Relay.Error.t()}
  def authorize(token) when is_binary(token) do
    with {:ok, verified} <- Subscriber.verify(token),
         :ok <- readable(verified.scopes),
         :ok <- tenant_active(verified.scope),
         {:ok, expires_at} <- expiry(token) do
      {:ok,
       %{
         scope: verified.scope,
         subscriber_id: verified.subscriber_id,
         scopes: verified.scopes,
         expires_at: expires_at
       }}
    end
  end

  def authorize(_token),
    do: {:error, Relay.Error.new(:auth_missing_credentials, "send a Relay subscriber token")}

  # IN-33
  @doc "True when `grant` speaks for the same subscriber in the same scope as `current`."
  @spec same_subject?(grant(), grant()) :: boolean()
  def same_subject?(grant, current),
    do: grant.scope == current.scope and grant.subscriber_id == current.subscriber_id

  # IN-33
  @doc "The signal topics whose events may withdraw a grant of `scope`."
  @spec topics(Relay.Scope.t()) :: [String.t()]
  def topics(scope) do
    case SubscriberSuspension.topic(scope) do
      {:ok, topic} -> [topic | shared_topics()]
      {:error, _} -> shared_topics()
    end
  end

  # IN-51
  @doc "Rereads the subscriber token keys when `topic` is their signal, so the next check sees a retired key at once."
  @spec refresh_keys(String.t()) :: :ok
  def refresh_keys(topic) do
    if topic == Relay.Access.subscriber_token_keys_topic() do
      _ = Relay.Access.subscriber_token_key_accepted?("", fresh: true)
    end

    :ok
  end

  defp shared_topics,
    do: [Relay.Access.client_changes_topic(), Relay.Access.subscriber_token_keys_topic()]

  # API-45
  @doc "The bearer token of a request, or `nil`."
  @spec bearer(Plug.Conn.t()) :: String.t() | nil
  def bearer(conn) do
    with [value] <- Plug.Conn.get_req_header(conn, "authorization"),
         [_, token] when is_binary(token) <- Regex.run(@bearer, value) do
      token
    else
      _ -> nil
    end
  end

  defp readable(scopes) do
    if Relay.Realtime.permitted?(scopes, :inbox),
      do: :ok,
      else: {:error, Relay.Error.new(:auth_insufficient_scope, "the token lacks inbox:read")}
  end

  # TN-10
  defp tenant_active(scope) do
    case Tenant.edge(scope) do
      {:ok, %{status: :active}} ->
        :ok

      {:ok, _inactive} ->
        {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

      {:error, _} = error ->
        error
    end
  end

  defp expiry(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"exp" => exp}} when is_integer(exp) <- Jason.decode(json) do
      {:ok, exp}
    else
      _ -> {:error, Relay.Error.new(:auth_invalid_token, "not a Relay subscriber token")}
    end
  end
end
