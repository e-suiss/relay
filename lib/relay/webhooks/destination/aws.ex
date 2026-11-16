defmodule Relay.Webhooks.Destination.Aws do
  @moduledoc """
  What the AWS destinations share (WH-17): the credentials of an endpoint, the regional API host and the signed call. A call is signed with `Relay.Webhooks.Destination.AwsSigV4` and sent through the egress boundary (WH-43).

  An endpoint authenticates with an access key (`access_key_id` and the secret access key as `credential`) or with an IAM role (`role_arn`):

  | Configuration | Credentials of the call |
  |---|---|
  | access key | the access key |
  | role and access key | the role, assumed with the access key |
  | role alone | the role, assumed with the identity of the installation |

  The identity of the installation is the `:aws_identity` option. A role assumed with it is always assumed with the external identifier of the `:aws_external_id` option, so that one tenant cannot name the role another tenant granted to the installation; without both options the role is not assumed. The temporary credentials of a role are kept by the caller's `:token_cache`, like an OAuth2 token, and the request for them goes through the egress boundary with the same limits. `:aws_session_s`, when given, is the lifetime asked for.

  The region is part of a host name and is checked before it is used. The secret access key, the session token and the temporary credentials are wrapped values and appear in no failure and in no receipt (WH-19).
  """

  alias Relay.Redacted
  alias Relay.Webhooks.Destination
  alias Relay.Webhooks.Destination.AwsSigV4
  alias Relay.Webhooks.Destination.Cloud

  @region ~r/\A[a-z0-9-]{1,32}\z/
  @arn ~r/\Aarn:[a-z0-9-]+:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:[A-Za-z0-9_+=,.@\/:-]{1,512}\z/
  @access_key_id ~r/\A[A-Z0-9]{16,128}\z/
  @group ~r/\A[\x21-\x7E]{1,128}\z/
  @form "application/x-www-form-urlencoded; charset=utf-8"
  @session_name "suiss-relay"
  @key_id_tag ~r/<AccessKeyId>([^<]+)<\/AccessKeyId>/
  @secret_tag ~r/<SecretAccessKey>([^<]+)<\/SecretAccessKey>/
  @token_tag ~r/<SessionToken>([^<]+)<\/SessionToken>/
  @expiration_tag ~r/<Expiration>([^<]+)<\/Expiration>/

  @type answer :: Cloud.answer() | {:error, Destination.failure()}

  @doc "The regional API host of a service."
  @spec host(String.t(), String.t()) :: String.t()
  def host(service, region) when is_binary(service) and is_binary(region),
    do: service <> "." <> region <> "." <> suffix(region)

  defp suffix("cn-" <> _rest), do: "amazonaws.com.cn"
  defp suffix(_region), do: "amazonaws.com"

  @doc "The region of a configuration, checked for the form of a region name."
  @spec region(map()) :: {:ok, String.t()} | {:error, Destination.failure()}
  def region(config) when is_map(config) do
    case Map.get(config, :region) do
      region when is_binary(region) -> checked_region(region)
      _other -> Cloud.invalid("region_invalid")
    end
  end

  defp checked_region(region) do
    if Regex.match?(@region, region), do: {:ok, region}, else: Cloud.invalid("region_invalid")
  end

  @doc "Whether a value has the form of an ARN."
  @spec arn?(term()) :: boolean()
  def arn?(value), do: is_binary(value) and byte_size(value) <= 640 and Regex.match?(@arn, value)

  # WH-20 (3)
  @doc "The message group of an event on a FIFO queue or topic: its ordering key, or its identifier when it has none. A key the service would not take as a group identifier is replaced by its SHA-256 digest, so that one subject is still one group."
  @spec group_id(Destination.prepared()) :: String.t()
  def group_id(%{partition_key: key, id: id}) do
    group = key || id

    if Regex.match?(@group, group),
      do: group,
      else: Base.encode16(:crypto.hash(:sha256, group), case: :lower)
  end

  # WH-17
  # WH-43
  @doc "Signs `request` for `service` with the credentials of the configuration and sends it. Options: those of `Relay.Webhooks.Destination.Cloud.request/2`, `:now`, and for a role `:token_cache`, `:aws_identity`, `:aws_external_id` and `:aws_session_s`."
  @spec call(map(), String.t(), AwsSigV4.request(), keyword()) :: answer()
  def call(config, service, request, opts) when is_map(config) and is_list(opts) do
    with {:ok, region} <- region(config),
         {:ok, credentials} <- credentials(config, region, opts) do
      signed(request, credentials, %{region: region, service: service}, opts)
    end
  end

  defp signed(request, credentials, scope, opts) do
    case AwsSigV4.sign(request, credentials, scope, Cloud.now(opts)) do
      {:ok, headers} -> Cloud.request(opts, %{request | headers: headers})
      {:error, :invalid_url} -> Cloud.invalid("invalid_url")
    end
  end

  defp credentials(config, region, opts) do
    case {Map.get(config, :role_arn), access_key(config)} do
      {_role, :invalid} -> Cloud.invalid("access_key_invalid")
      {nil, :none} -> Cloud.invalid("credentials_missing")
      {nil, {:ok, key}} -> {:ok, key}
      {role, base} -> assumed(role, base, region, opts)
    end
  end

  defp access_key(config) do
    id = Map.get(config, :access_key_id)
    secret = Map.get(config, :credential)

    cond do
      id == nil and secret == nil -> :none
      key_id?(id) and secret?(secret) -> {:ok, key(id, secret)}
      true -> :invalid
    end
  end

  defp key(id, secret), do: %{access_key_id: id, secret_access_key: secret, session_token: nil}

  defp key_id?(id), do: is_binary(id) and Regex.match?(@access_key_id, id)

  defp secret?(secret), do: Redacted.redacted?(secret) and is_binary(Redacted.expose(secret))

  # WH-17
  defp assumed(role, base, region, opts) do
    with true <- arn?(role),
         {:ok, identity, external_id} <- identity(base, opts),
         fetch = fn -> assume(role, identity, external_id, region, opts) end,
         {:ok, session} <- Cloud.cached(opts, fetch) do
      {:ok, Redacted.expose(session)}
    else
      false -> Cloud.invalid("role_arn_invalid")
      {:error, failure} -> {:error, failure}
    end
  end

  defp identity({:ok, key}, _opts), do: {:ok, key, nil}

  defp identity(:none, opts) do
    identity = Keyword.get(opts, :aws_identity)
    external_id = Keyword.get(opts, :aws_external_id)

    cond do
      not identity?(identity) ->
        Cloud.unattempted(:credentials, "installation_identity_missing")

      is_binary(external_id) and external_id != "" ->
        {:ok, identity, external_id}

      true ->
        Cloud.unattempted(:credentials, "external_id_missing")
    end
  end

  defp identity?(%{access_key_id: id, secret_access_key: secret}),
    do: is_binary(id) and secret?(secret)

  defp identity?(_identity), do: false

  # WH-43
  defp assume(role, identity, external_id, region, opts) do
    request = %{
      method: "POST",
      url: "https://" <> host("sts", region) <> "/",
      headers: [{"content-type", @form}],
      body: assume_body(role, external_id, opts)
    }

    case signed(request, identity, %{region: region, service: "sts"}, opts) do
      {:ok, %{status: 200, truncated: false} = response} -> session(response, opts)
      answer -> Cloud.credential_failure("sts", answer)
    end
  end

  defp assume_body(role, external_id, opts) do
    fixed = [
      {"Action", "AssumeRole"},
      {"Version", "2011-06-15"},
      {"RoleArn", role},
      {"RoleSessionName", @session_name}
    ]

    URI.encode_query(fixed ++ external(external_id) ++ duration(opts))
  end

  defp external(nil), do: []
  defp external(external_id), do: [{"ExternalId", external_id}]

  defp duration(opts) do
    case Keyword.get(opts, :aws_session_s) do
      seconds when is_integer(seconds) -> [{"DurationSeconds", Integer.to_string(seconds)}]
      _absent -> []
    end
  end

  # WH-19
  defp session(%{body: body} = response, opts) do
    with [key_id] <- capture(@key_id_tag, body),
         [secret] <- capture(@secret_tag, body),
         [token] <- capture(@token_tag, body) do
      credentials = %{
        access_key_id: key_id,
        secret_access_key: Redacted.wrap(secret),
        session_token: Redacted.wrap(token)
      }

      {:ok, Redacted.wrap(credentials), lifetime(body, Cloud.now(opts))}
    else
      _unreadable -> {:error, Cloud.failure(:credentials, "sts_response_invalid", response)}
    end
  end

  defp capture(regex, body) do
    case Regex.run(regex, body, capture: :all_but_first) do
      [value] -> [Relay.Binary.keep(value)]
      nil -> []
    end
  end

  defp lifetime(body, now) do
    with [expiration] <- capture(@expiration_tag, body),
         {:ok, at, _offset} <- DateTime.from_iso8601(expiration),
         seconds when seconds > 0 <- DateTime.diff(at, now, :second) do
      seconds
    else
      _unknown -> nil
    end
  end
end
