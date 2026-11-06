defmodule Relay.Channels.Hms do
  @moduledoc """
  The Huawei Push Kit adapter (CH-1, CH-27). It sends one message to one token through the Push Kit server API (`messages:send`), authenticated with the app's OAuth 2.0 client credentials token; the client secret is the account credential and the token is held per tenant environment and app for its lifetime (`Relay.Channels.Push.Tokens`).

  The Relay message class maps to the HMS classification by the fixed table of `push_priority_map` and never by the tenant (CH-27): `security`, `transactional`, `operational` and `action_required` go as service and communication messages (importance `NORMAL`), `marketing` and `social` as news and marketing messages (importance `LOW`). The FCM priority of the table sets the HMS `urgency`, the message's `expires_at` the `ttl`; a `system` or content-free message is a data message with the opaque identifier and neutral text only (CH-33). A raw `hms.android` override is merged deeply into the `android` block and cannot change the `urgency`, the `importance` or the `category`; its ignored paths are reported as `override_ignored`, and a data message drops it (CH-21). An HMS answer is accepted only with the success code `80000000`, and acceptance is never delivery (CH-32).

  The account settings: `app_id` and `client_id`. The installation configuration `config :relay, Relay.Channels.Hms, token_url: url, send_url: url, http: opts` replaces the endpoints and the client options.
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Push.Common
  alias Relay.Channels.Push.Content
  alias Relay.Channels.Push.Failures
  alias Relay.Channels.Push.Override
  alias Relay.Channels.Push.Tokens
  alias Relay.Channels.Push.Ttl
  alias Relay.Channels.Request

  @token_url "https://oauth-login.cloud.huawei.com/oauth2/v3/token"
  @send_url "https://push-api.cloud.huawei.com/v1/"
  @max_bytes 4096
  @skew 60

  @impl Relay.Channels.Adapter
  def provider, do: "hms"

  @impl Relay.Channels.Adapter
  def channels, do: ["push"]

  # CH-27
  # TN-30
  @impl Relay.Channels.Adapter
  def deliver(%Request{push: %{} = push} = request) do
    with {:ok, settings} <- Common.settings(request, ["app_id", "client_id"]),
         {:ok, ttl} <- ttl(push),
         {:ok, body, ignored} <- body(request, push, ttl),
         {:ok, token} <- token(request, settings) do
      call(request, settings, token, body, ignored)
    else
      {:error, :expired} -> {:not_sent, "expired"}
      {:error, :token_unavailable} -> {:not_sent, "auth_unavailable"}
      {:error, reason} -> Common.rejection(reason)
    end
  end

  def deliver(%Request{}), do: Common.rejection(:not_configured)

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(response), do: %{code: Failures.code(:hms, response)}

  defp ttl(push) do
    case Ttl.fcm(push.expires_at, push.now) do
      {:ok, ttl} -> {:ok, ttl}
      :expired -> {:error, :expired}
    end
  end

  # CH-21
  # CH-27
  # CH-33
  # INV-60
  defp body(request, push, ttl) do
    data_message = push.message_class == :system or push.content_free
    urgency = if push.mapping.fcm_priority == :high, do: "HIGH", else: "NORMAL"
    android = %{"urgency" => urgency, "ttl" => ttl}
    android = if data_message, do: android, else: notification(android, request, push)
    override = Common.override(request, "hms", "android")
    {android, ignored} = android(android, override, data_message)
    data = data(request, push)

    message = %{
      "token" => [Relay.Redacted.expose(request.target.value)],
      "android" => android,
      "data" => Jason.encode!(data)
    }

    body = Jason.encode!(%{"validate_only" => false, "message" => message})

    with :ok <- Content.check(%{"android" => android, "data" => data}),
         {:ok, body} <- size(body),
         do: {:ok, body, ignored}
  end

  defp android(android, nil, _data_message), do: {android, []}
  defp android(android, _override, true), do: {android, ["hms.android"]}
  defp android(android, override, false), do: Override.hms_android(android, override)

  defp size(body) when byte_size(body) <= @max_bytes, do: {:ok, body}

  defp size(_body),
    do: {:error, Relay.Error.new(:push_payload_too_large, "the HMS message is too large")}

  defp notification(android, request, push) do
    fields = Map.take(Common.fields(request), ["title", "body"])

    notification =
      Map.merge(fields, %{
        "importance" => push.mapping.hms_importance || "NORMAL",
        "click_action" => %{"type" => 3}
      })

    Map.put(android, "notification", notification)
  end

  defp data(request, push) do
    base = %{"relay_id" => Common.content_id(request)}
    base = if push.collapse, do: Map.put(base, "relay_topic", push.collapse.topic), else: base

    cond do
      push.content_free and push.message_class != :system ->
        Map.put(base, "neutral", Content.neutral(push.locale, push.lock_screen_body))

      push.content_free ->
        base

      true ->
        link(base, Common.link(request))
    end
  end

  # E-83
  defp link(data, nil), do: data
  defp link(data, url), do: Map.put(data, "relay_url", url)

  # TN-30
  defp token(%Request{credentials: nil}, _settings), do: {:error, :not_configured}

  defp token(%Request{credentials: secret} = request, settings) do
    scope = request.scope
    key = {scope.tenant_id, scope.environment, "hms", settings["app_id"]}
    now = DateTime.to_unix(Relay.Clock.utc_now())
    fetch = fn -> fetch_token(settings, secret, now, request.timeout_ms) end

    case Tokens.fetch(key, now, @skew, fetch) do
      {:ok, token} -> {:ok, token}
      {:error, _reason} -> {:error, :token_unavailable}
    end
  end

  defp fetch_token(settings, secret, now, timeout_ms) do
    form = [
      grant_type: "client_credentials",
      client_id: settings["client_id"],
      client_secret: Relay.Redacted.expose(secret)
    ]

    request = %{
      method: :post,
      url: Common.config(__MODULE__, :token_url, @token_url),
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: URI.encode_query(form, :www_form)
    }

    with {:ok, %{status: 200, body: body}} <- Common.http(__MODULE__, request, timeout_ms),
         {:ok, %{"access_token" => token, "expires_in" => seconds}} <- Jason.decode(body),
         true <- is_binary(token) and is_integer(seconds) do
      {:ok, %{token: Relay.Redacted.wrap(token), expires_at: now + seconds}}
    else
      _failed -> {:error, :token_unavailable}
    end
  end

  defp call(request, settings, token, body, ignored) do
    app = URI.encode(settings["app_id"], &URI.char_unreserved?/1)

    http = %{
      method: :post,
      url: Common.config(__MODULE__, :send_url, @send_url) <> app <> "/messages:send",
      headers: [
        {"authorization", "Bearer " <> Relay.Redacted.expose(token)},
        {"content-type", "application/json; charset=utf-8"}
      ],
      body: body
    }

    case Common.http(__MODULE__, http, request.timeout_ms) do
      {:ok, response} -> answer(response, ignored)
      {:error, :not_sent} -> {:not_sent, "connect_failed"}
      {:error, :uncertain} -> {:uncertain, "no_answer"}
    end
  end

  # CH-32
  defp answer(response, ignored) do
    case Failures.read(:hms, response, Relay.Clock.utc_now()) do
      :accepted ->
        id =
          case Jason.decode(response.body) do
            {:ok, %{"requestId" => id}} when is_binary(id) -> id
            _other -> nil
          end

        {:accepted, %{provider_message_id: id, detail: %{override_ignored: ignored}}}

      {:rejected, raw} ->
        {:rejected, raw}
    end
  end
end
