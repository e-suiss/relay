defmodule Relay.Channels.Teams do
  @moduledoc """
  The Microsoft Teams adapter (CH-62, CH-3): the tenant's Bot Framework bot sends a proactive message to a stored `conversationReference`; the retired Office 365 Connectors and incoming webhooks are never used (CH-4). A proactive message needs the app installed for the user or the team, and the reference is captured from the bot's own inbound activity.

    * The credential is the bot's JSON identity, `{"app_id", "app_password", "tenant_id"}` (`tenant_id` is the bot's Entra tenant, `botframework.com` for a multi-tenant bot). Each call first takes a Bot Framework access token with the client credentials grant; the token is used for this call only and kept nowhere (TN-26). A token request that fails sent nothing to Teams.
    * The target is the JSON reference `{"service_url", "conversation_id"}`; only an `https` service URL of the Bot Framework hosts is called.
    * A message about a subject that already has an activity in the conversation updates that activity (CH-23); an activity Teams no longer knows is posted again. The provider message reference is the activity ID.

  Teams gives no delivery or read information; `Action.Execute`, messages and installation updates arrive at the bot's messaging endpoint and are recorded as events only. The raw code of a failure is the Bot Framework `error.code`, `http_<status>` without one, and `token_<error>` for a failed token request.

  The settings check takes a Bot Framework access token with the bot's identity and sends nothing to Teams: a token endpoint that refuses the client (`invalid_client`, `unauthorized_client`, `401`) is a credential mismatch (CH-14, CH-52).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Messaging
  alias Relay.Channels.ProviderHttp
  alias Relay.Channels.Request
  alias Relay.Channels.SettingsCheck

  @login "https://login.microsoftonline.com/"
  @scope "https://api.botframework.com/.default"
  @hosts ~r/(\A|\.)(botframework\.com|trafficmanager\.net|botframework\.azure\.us)\z/
  @refused ~w(invalid_client unauthorized_client invalid_request invalid_grant)

  @impl Relay.Channels.Adapter
  def provider, do: "teams"

  @impl Relay.Channels.Adapter
  def channels, do: ["teams"]

  @impl Relay.Channels.Adapter
  def deliver(%Request{} = request), do: deliver(request, [])

  # CH-62
  # CH-23
  @doc "Delivers a request with extra HTTP client options; see `c:Relay.Channels.Adapter.deliver/1`."
  @spec deliver(Request.t(), keyword()) :: Relay.Channels.Adapter.result()
  def deliver(%Request{} = request, opts) do
    with {:ok, identity} <- identity(request),
         {:ok, conversation} <- conversation(request),
         {:ok, token} <- token(request, identity, opts) do
      send_activity(request, conversation, token, opts)
    end
  end

  # CH-14
  # CH-52
  @impl Relay.Channels.Adapter
  def check_settings(%{credentials: credentials, timeout_ms: timeout_ms}) do
    value = if credentials, do: Relay.Redacted.expose(credentials)

    case parse_identity(value) do
      {:ok, identity} ->
        http = token_request(identity)

        case ProviderHttp.call(http, timeout_ms) do
          {:ok, %Req.Response{status: 400, body: body}} -> token_refused(body)
          answer -> SettingsCheck.read(answer, &token_checked/1)
        end

      :error ->
        SettingsCheck.credentials(nil)
    end
  end

  defp token_checked(%Req.Response{status: 200, body: body}) do
    case Messaging.json(body) do
      %{"access_token" => token} when is_binary(token) -> :ok
      _other -> {:error, "token_unexpected_response"}
    end
  end

  defp token_checked(%Req.Response{status: status}),
    do: {:error, "token_" <> Messaging.http_code(status)}

  defp token_refused(body) do
    case Messaging.json(body) do
      %{"error" => error} when error in @refused -> SettingsCheck.credentials("token_" <> error)
      _other -> {:error, "token_http_400"}
    end
  end

  defp identity(request) do
    case parse_identity(Messaging.credential(request)) do
      {:ok, identity} -> {:ok, identity}
      :error -> {:rejected, %{code: "credential_missing", status: nil}}
    end
  end

  defp parse_identity(%{"app_id" => id, "app_password" => password} = identity)
       when is_binary(id) and is_binary(password),
       do: {:ok, %{id: id, password: password, tenant: Map.get(identity, "tenant_id")}}

  defp parse_identity(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = identity} -> parse_identity(identity)
      _invalid -> :error
    end
  end

  defp parse_identity(_value), do: :error

  # CH-62
  @doc "Parses a stored conversation reference; only an `https` service URL of a Bot Framework host is accepted."
  @spec reference(String.t()) ::
          {:ok, %{service_url: String.t(), conversation_id: String.t()}} | :error
  def reference(value) when is_binary(value) do
    with {:ok, %{"service_url" => url, "conversation_id" => id}}
         when is_binary(url) and is_binary(id) and id != "" <- Jason.decode(value),
         %URI{scheme: "https", host: host} when is_binary(host) <- URI.parse(url),
         true <- Regex.match?(@hosts, String.downcase(host)) do
      {:ok, %{service_url: String.trim_trailing(url, "/"), conversation_id: id}}
    else
      _invalid -> :error
    end
  end

  defp conversation(request) do
    case reference(Messaging.target(request)) do
      {:ok, reference} -> {:ok, reference}
      :error -> {:rejected, %{code: "target_invalid", status: nil}}
    end
  end

  defp token_request(identity) do
    tenant = if is_binary(identity.tenant), do: identity.tenant, else: "botframework.com"

    [
      method: :post,
      url: @login <> URI.encode(tenant) <> "/oauth2/v2.0/token",
      form: [
        grant_type: "client_credentials",
        client_id: identity.id,
        client_secret: identity.password,
        scope: @scope
      ]
    ]
  end

  defp token(request, identity, opts) do
    http = token_request(identity)

    case Messaging.send(request, Keyword.merge(http, opts)) do
      {:ok, %{status: 200, body: body}} -> access_token(body)
      {:ok, response} -> {:rejected, token_failure(response.status, response.body)}
      {:error, exception} -> {:not_sent, elem(Messaging.transport(exception), 1)}
    end
  end

  defp access_token(body) do
    case Messaging.json(body) do
      %{"access_token" => token} when is_binary(token) -> {:ok, token}
      decoded -> {:rejected, token_failure(200, decoded)}
    end
  end

  defp token_failure(status, body) do
    case Messaging.json(body) do
      %{"error" => error} when is_binary(error) -> %{code: "token_" <> error, status: status}
      _other -> %{code: "token_" <> Messaging.http_code(status), status: status}
    end
  end

  defp send_activity(request, conversation, token, opts) do
    fields = Messaging.fields(request.content)
    id = URI.encode_www_form(conversation.conversation_id)
    base = conversation.service_url <> "/v3/conversations/" <> id <> "/activities"

    case request.update do
      id when is_binary(id) and id != "" ->
        body = Map.put(activity(fields), "id", id)

        case call(request, token, :put, base <> "/" <> URI.encode_www_form(id), body, opts) do
          {:rejected, %{status: 404}} -> post(request, token, base, fields, opts)
          {:accepted, _info} -> {:accepted, %{provider_message_id: id}}
          result -> result
        end

      _new ->
        post(request, token, base, fields, opts)
    end
  end

  defp post(request, token, base, fields, opts),
    do: call(request, token, :post, base, activity(fields), opts)

  # CH-62
  # INV-29
  @doc "The message activity of rendered fields: the text, and an Adaptive Card with one `Action.OpenUrl` when the fields carry a link."
  @spec activity(Messaging.fields()) :: map()
  def activity(fields) do
    text = Messaging.text(fields)
    base = %{"type" => "message", "text" => text, "textFormat" => "plain"}

    case Messaging.link(fields) do
      nil ->
        base

      {label, url} ->
        card = %{
          "type" => "AdaptiveCard",
          "version" => "1.4",
          "body" => [%{"type" => "TextBlock", "text" => text, "wrap" => true}],
          "actions" => [%{"type" => "Action.OpenUrl", "title" => label, "url" => url}]
        }

        Map.put(base, "attachments", [
          %{"contentType" => "application/vnd.microsoft.card.adaptive", "content" => card}
        ])
    end
  end

  defp call(request, token, method, url, body, opts) do
    http = [
      method: method,
      url: url,
      headers: [
        {"authorization", "Bearer " <> token},
        {"content-type", "application/json"}
      ],
      body: Jason.encode!(body)
    ]

    case Messaging.send(request, Keyword.merge(http, opts)) do
      {:ok, response} ->
        result(response.status, response.body, Messaging.retry_after_ms(response))

      {:error, exception} ->
        Messaging.transport(exception)
    end
  end

  defp result(status, body, retry_after_ms) do
    case Messaging.json(body) do
      %{"id" => id} when status in 200..299 and is_binary(id) ->
        {:accepted, %{provider_message_id: id}}

      _empty when status in 200..299 ->
        {:accepted, %{}}

      decoded ->
        {:rejected, raw(status, decoded, retry_after_ms)}
    end
  end

  defp raw(429, _decoded, retry_after_ms),
    do: %{code: "http_429", status: 429, retry_after_ms: retry_after_ms}

  defp raw(status, %{"error" => %{"code" => code}}, retry_after_ms)
       when is_binary(code) and code != "",
       do: %{code: code, status: status, retry_after_ms: retry_after_ms}

  defp raw(status, _decoded, retry_after_ms),
    do: %{code: Messaging.http_code(status), status: status, retry_after_ms: retry_after_ms}

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(%{"status" => status} = response) do
    retry_after_ms = Messaging.vector_retry_after_ms(response)

    case {Map.get(response, "call"), status} do
      {"token", 200} ->
        %{code: "accepted", status: 200}

      {"token", _status} ->
        token_failure(status, Map.get(response, "body"))

      _activity ->
        decoded(result(status, Map.get(response, "body"), retry_after_ms), status)
    end
  end

  defp decoded({:accepted, _info}, status), do: %{code: "accepted", status: status}
  defp decoded({:rejected, raw}, _status), do: raw
end
