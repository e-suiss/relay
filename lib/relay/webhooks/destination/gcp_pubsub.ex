defmodule Relay.Webhooks.Destination.GcpPubsub do
  @moduledoc """
  The Google Cloud Pub/Sub destination (WH-17): one `publish` call of the Pub/Sub REST API with one message, sent through the egress boundary (WH-43). Success is the 2xx answer, which Pub/Sub gives once the message is stored (WH-18).

  Configuration: `:project_id`, `:topic`, the service account key (the JSON key file) as `:credential`, and `:cloudevents_mode` (`"binary"` by default).

  The endpoint authenticates as its service account: a JWT signed with the account's key is exchanged for an access token at Google's token endpoint, through the egress boundary and with the same limits. The token is never held here: the caller's `:token_cache` is given the fetch function and returns the token of this endpoint, fetching only when it has none that is still valid. `:assertion_ttl_s` is the lifetime of the signed assertion. The key, the assertion and the token are wrapped or short-lived values and appear in no failure and in no receipt (WH-19).

  The message follows the CloudEvents Pub/Sub binding (WH-8 (3)). In binary mode the message data is `data`, the context attributes are message attributes with the `ce-` prefix and `content-type` is the content type of the data. In structured mode the data is the whole event and `content-type` names its format. The CloudEvents `id` is always the `ce-id` attribute, the key a subscriber deduplicates on (WH-18), and the ordering key of the event is the ordering key of the message, so the events of one subject keep their order for a subscription that asks for ordering (WH-20 (3)).
  """

  @behaviour Relay.Webhooks.Destination

  alias Relay.Redacted
  alias Relay.Webhooks.Destination.Cloud

  @host "pubsub.googleapis.com"
  @token_url "https://oauth2.googleapis.com/token"
  @scope "https://www.googleapis.com/auth/pubsub"
  @grant "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @project ~r/\A[a-z][a-z0-9-]{4,28}[a-z0-9]\z/
  @topic ~r/\A[A-Za-z][A-Za-z0-9._~%+-]{2,254}\z/

  # WH-17
  # WH-18
  @impl Relay.Webhooks.Destination
  def deliver(config, prepared, opts) when is_map(config) and is_list(opts) do
    with {:ok, url} <- url(config),
         {:ok, mode} <- Cloud.mode(config, :binary),
         {:ok, token} <- token(config, opts) do
      headers = [
        {"content-type", "application/json"},
        {"authorization", "Bearer " <> Redacted.expose(token)}
      ]

      body = Jason.encode!(%{"messages" => [message(mode, prepared)]})
      request = %{method: "POST", url: url, headers: headers, body: body}
      opts |> Cloud.request(request) |> Cloud.settle()
    end
  end

  defp url(config) do
    project = Map.get(config, :project_id)
    topic = Map.get(config, :topic)

    if matches?(@project, project) and matches?(@topic, topic) do
      path = "/v1/projects/" <> project <> "/topics/" <> encode(topic) <> ":publish"
      {:ok, "https://" <> @host <> path}
    else
      Cloud.invalid("topic_invalid")
    end
  end

  defp matches?(regex, value), do: is_binary(value) and Regex.match?(regex, value)

  defp encode(text), do: URI.encode(text, &URI.char_unreserved?/1)

  # WH-8 (3)
  # WH-18
  defp message(mode, prepared) do
    message = %{
      "data" => Base.encode64(data(mode, prepared)),
      "attributes" => Map.new(attributes(mode, prepared))
    }

    ordered(message, prepared.partition_key)
  end

  defp data(:binary, prepared), do: prepared.data
  defp data(:structured, prepared), do: prepared.body

  defp attributes(:binary, prepared) do
    context =
      for {name, value} <- prepared.attributes, name != "datacontenttype" do
        {"ce-" <> name, value}
      end

    [{"content-type", Cloud.data_content_type(prepared)} | context]
  end

  defp attributes(:structured, prepared),
    do: [{"content-type", prepared.content_type}, {"ce-id", prepared.id}]

  # WH-20 (3)
  defp ordered(message, nil), do: message
  defp ordered(message, key), do: Map.put(message, "orderingKey", key)

  # WH-17
  # WH-19
  defp token(config, opts) do
    credential = Map.get(config, :credential)

    if Redacted.redacted?(credential),
      do: Cloud.cached(opts, fn -> fetch(credential, opts) end),
      else: Cloud.invalid("credentials_missing")
  end

  defp fetch(credential, opts) do
    case account(Redacted.expose(credential)) do
      {:ok, account} -> exchange(assertion(account, opts), opts)
      :error -> Cloud.invalid("service_account_invalid")
    end
  end

  defp account(json) when is_binary(json) do
    with {:ok, %{"client_email" => email, "private_key" => pem} = key} <- Jason.decode(json),
         true <- is_binary(email) and email != "" and is_binary(pem),
         {:ok, private_key} <- private_key(pem) do
      {:ok, %{email: email, key: private_key, key_id: Map.get(key, "private_key_id")}}
    else
      _invalid -> :error
    end
  end

  defp account(_other), do: :error

  defp private_key(pem) do
    with [entry] <- :public_key.pem_decode(pem),
         key when elem(key, 0) == :RSAPrivateKey <- :public_key.pem_entry_decode(entry) do
      {:ok, key}
    else
      _invalid -> :error
    end
  rescue
    _error -> :error
  end

  defp assertion(account, opts) do
    issued = DateTime.to_unix(Cloud.now(opts))

    claims = %{
      "iss" => account.email,
      "scope" => @scope,
      "aud" => @token_url,
      "iat" => issued,
      "exp" => issued + Keyword.fetch!(opts, :assertion_ttl_s)
    }

    input = segment(header(account.key_id)) <> "." <> segment(claims)
    signature = :public_key.sign(input, :sha256, account.key)
    input <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp header(key_id) when is_binary(key_id),
    do: %{"alg" => "RS256", "typ" => "JWT", "kid" => key_id}

  defp header(_key_id), do: %{"alg" => "RS256", "typ" => "JWT"}

  defp segment(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  # WH-43
  defp exchange(assertion, opts) do
    request = %{
      method: "POST",
      url: @token_url,
      headers: [
        {"content-type", "application/x-www-form-urlencoded"},
        {"accept", "application/json"}
      ],
      body: URI.encode_query([{"grant_type", @grant}, {"assertion", assertion}])
    }

    case Cloud.request(opts, request) do
      {:ok, %{status: 200, truncated: false} = response} -> access_token(response)
      answer -> Cloud.credential_failure("token_endpoint", answer)
    end
  end

  defp access_token(response) do
    case Jason.decode(response.body) do
      {:ok, %{"access_token" => token} = body} when is_binary(token) and token != "" ->
        {:ok, Redacted.wrap(token), lifetime(body)}

      _other ->
        {:error, Cloud.failure(:credentials, "token_response_invalid", response)}
    end
  end

  defp lifetime(%{"expires_in" => seconds}) when is_integer(seconds) and seconds > 0, do: seconds
  defp lifetime(_body), do: nil
end
