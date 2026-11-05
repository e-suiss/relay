defmodule Relay.Channels.Push.Fcm.Auth do
  @moduledoc """
  The OAuth 2.0 access token of an FCM project (TN-30). Workload Identity Federation is preferred: the workload's own identity token is exchanged at the Google Security Token Service (RFC 8693) and, when a service account is named, exchanged again for that account's token, so no service account key exists anywhere. Where federation cannot be set up, the service account's RSA key is imported into the key store and the RS256 JWT bearer assertion (RFC 7523) is signed there (TN-28, TN-35).

  The access token is cached per project for its lifetime, less one minute, and comes back as `Relay.Redacted`. The HTTP call is the adapter's: every request is a value (`token_request/2`, `sts_request/2`, `impersonation_request/2`) and `access_token/4` takes the function that sends it.
  """

  alias Relay.Channels.Push.Jwt
  alias Relay.Error

  @scope "https://www.googleapis.com/auth/firebase.messaging"
  @cloud_scope "https://www.googleapis.com/auth/cloud-platform"
  @token_url "https://oauth2.googleapis.com/token"
  @sts_url "https://sts.googleapis.com/v1/token"
  @iam_url "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/"
  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @token_exchange "urn:ietf:params:oauth:grant-type:token-exchange"
  @access_token_type "urn:ietf:params:oauth:token-type:access_token"
  @lifetime 3600
  @skew 60

  @typedoc "A service account whose RSA key is in the key store under `label`."
  @type service_account :: %{
          kind: :service_account,
          project_id: String.t(),
          client_email: String.t(),
          private_key_id: String.t(),
          label: Relay.Keys.label()
        }

  @typedoc "Workload Identity Federation: the provider `audience` and the type of the workload's subject token, with an optional service account to impersonate."
  @type workload_identity :: %{
          required(:kind) => :workload_identity,
          required(:project_id) => String.t(),
          required(:audience) => String.t(),
          required(:subject_token_type) => String.t(),
          optional(:service_account) => String.t() | nil
        }

  @type source :: service_account() | workload_identity()

  @type request :: %{
          method: :post,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: String.t()
        }

  @typedoc "An HTTP response as the adapter's client returns it; the body is raw JSON or decoded."
  @type response :: %{status: pos_integer(), body: binary() | map()}

  @type http :: (request() -> {:ok, response()} | {:error, term()})

  @typedoc "Cached tokens by project."
  @type cache :: %{optional(String.t()) => entry()}

  @typedoc "A cached access token and its expiry in Unix seconds."
  @type entry :: %{token: Relay.Redacted.t(), expires_at: integer()}

  # TN-30
  # TN-28
  @doc "The RS256 assertion of a service account at Unix time `now`, signed in the key store."
  @spec assertion(service_account(), integer(), Jwt.signer()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def assertion(%{kind: :service_account} = sa, now, signer \\ &Relay.Keys.sign/3)
      when is_integer(now) do
    claims = [
      {"iss", sa.client_email},
      {"scope", @scope},
      {"aud", @token_url},
      {"iat", now},
      {"exp", now + @lifetime}
    ]

    Jwt.sign(:rs256, sa.label, [{"typ", "JWT"}, {"kid", sa.private_key_id}], claims, signer)
  end

  # TN-30
  @doc "The token request that exchanges an assertion for an access token."
  @spec token_request(service_account(), String.t()) :: request()
  def token_request(%{kind: :service_account}, assertion) when is_binary(assertion),
    do: form(@token_url, grant_type: @jwt_bearer, assertion: assertion)

  # TN-30
  @doc "The Security Token Service request that exchanges the workload's subject token."
  @spec sts_request(workload_identity(), String.t()) :: request()
  def sts_request(%{kind: :workload_identity} = wif, subject_token)
      when is_binary(subject_token) do
    scope = if Map.get(wif, :service_account), do: @cloud_scope, else: @scope

    form(@sts_url,
      grant_type: @token_exchange,
      audience: wif.audience,
      scope: scope,
      requested_token_type: @access_token_type,
      subject_token_type: wif.subject_token_type,
      subject_token: subject_token
    )
  end

  # TN-30
  @doc "The request that exchanges a federated token for the named service account's access token."
  @spec impersonation_request(workload_identity(), Relay.Redacted.t()) :: request()
  def impersonation_request(%{kind: :workload_identity, service_account: sa}, federated)
      when is_binary(sa) do
    %{
      method: :post,
      url: @iam_url <> URI.encode(sa, &URI.char_unreserved?/1) <> ":generateAccessToken",
      headers: [
        {"authorization", "Bearer " <> Relay.Redacted.expose(federated)},
        {"content-type", "application/json"}
      ],
      body: Jason.encode!(%{"scope" => [@scope], "lifetime" => "#{@lifetime}s"})
    }
  end

  defp form(url, fields) do
    %{
      method: :post,
      url: url,
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: URI.encode_query(fields, :www_form)
    }
  end

  # TN-30
  @doc "Reads an OAuth token response (`access_token`, `expires_in`) or an impersonation response (`accessToken`, `expireTime`) at Unix time `now`."
  @spec parse(response(), integer()) ::
          {:ok, entry()} | {:error, Error.t()}
  def parse(%{status: 200, body: body}, now) when is_integer(now) do
    case decode(body) do
      {:ok, %{"access_token" => token, "expires_in" => seconds}}
      when is_binary(token) and is_integer(seconds) and seconds > 0 ->
        {:ok, %{token: Relay.Redacted.wrap(token), expires_at: now + seconds}}

      {:ok, %{"accessToken" => token, "expireTime" => time}} when is_binary(token) ->
        expire_time(token, time)

      _other ->
        {:error, Error.new(:fcm_auth_failed, "the token response is malformed")}
    end
  end

  def parse(%{status: status}, _now) when is_integer(status),
    do: {:error, Error.new(:fcm_auth_failed, "the token endpoint refused", %{status: status})}

  defp expire_time(token, time) do
    case DateTime.from_iso8601(to_string(time)) do
      {:ok, at, _offset} ->
        {:ok, %{token: Relay.Redacted.wrap(token), expires_at: DateTime.to_unix(at)}}

      {:error, _reason} ->
        {:error, Error.new(:fcm_auth_failed, "the token response is malformed")}
    end
  end

  defp decode(%{} = body), do: {:ok, body}
  defp decode(body) when is_binary(body), do: Jason.decode(body)

  # TN-30
  @doc """
  The access token of the source's project at Unix time `now`, from `cache` while it has more than a minute left, otherwise fetched through `opts[:http]` and cached. A service account signs through `opts[:signer]` (`Relay.Keys.sign/3`); workload identity reads the workload's subject token from `opts[:subject_token]`, a function returning `{:ok, token}`.
  """
  @spec access_token(source(), cache(), integer(), keyword()) ::
          {:ok, Relay.Redacted.t(), cache()} | {:error, Error.t()}
  def access_token(%{project_id: project} = source, cache, now, opts)
      when is_map(cache) and is_integer(now) and is_list(opts) do
    case Map.get(cache, project) do
      %{token: token, expires_at: at} when at - now > @skew ->
        {:ok, token, cache}

      _missing_or_due ->
        with {:ok, entry} <- fetch(source, now, opts),
             do: {:ok, entry.token, Map.put(cache, project, entry)}
    end
  end

  defp fetch(%{kind: :service_account} = sa, now, opts) do
    http = Keyword.fetch!(opts, :http)

    with {:ok, assertion} <- assertion(sa, now, Keyword.get(opts, :signer, &Relay.Keys.sign/3)),
         {:ok, response} <- call(http, token_request(sa, assertion)),
         do: parse(response, now)
  end

  defp fetch(%{kind: :workload_identity} = wif, now, opts) do
    http = Keyword.fetch!(opts, :http)
    subject_token = Keyword.fetch!(opts, :subject_token)

    with {:ok, subject} <- subject(subject_token),
         {:ok, response} <- call(http, sts_request(wif, subject)),
         {:ok, federated} <- parse(response, now) do
      impersonate(wif, federated, http, now)
    end
  end

  defp impersonate(%{service_account: sa} = wif, federated, http, now) when is_binary(sa) do
    with {:ok, response} <- call(http, impersonation_request(wif, federated.token)),
         do: parse(response, now)
  end

  defp impersonate(_wif, federated, _http, _now), do: {:ok, federated}

  defp subject(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, token} when is_binary(token) and token != "" -> {:ok, token}
      _other -> {:error, Error.new(:fcm_auth_failed, "no workload identity token")}
    end
  end

  defp call(http, request) do
    case http.(request) do
      {:ok, %{status: status} = response} when is_integer(status) -> {:ok, response}
      _other -> {:error, Error.new(:fcm_auth_unavailable, "the token endpoint did not answer")}
    end
  end
end
