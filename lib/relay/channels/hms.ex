defmodule Relay.Channels.Hms do
  @moduledoc """
  The Huawei Push Kit adapter (CH-1, CH-27). It sends one message to one token through the Push Kit server API (`messages:send`), authenticated with the app's OAuth 2.0 client credentials token; the client secret is the account credential and the token is held per tenant environment and app for its lifetime (`Relay.Channels.Push.Tokens`).

  The Relay message class maps to the HMS classification by the fixed table of `push_priority_map` and never by the tenant (CH-27): `security`, `transactional`, `operational` and `action_required` go as service and communication messages (importance `NORMAL`), `marketing` and `social` as news and marketing messages (importance `LOW`). The FCM priority of the table sets the HMS `urgency`, the message's `expires_at` the `ttl`; a `system` or content-free message is a data message with the opaque identifier and neutral text only (CH-33). An HMS answer is accepted only with the success code `80000000`, and acceptance is never delivery (CH-32).

  The account settings: `app_id` and `client_id`.

  The settings check takes a new OAuth token with the client credentials and sends a `validate_only` message to a topic, which Push Kit validates for the app without delivering it (CH-14, CH-52): a token endpoint that refuses the client, `401`, `403` or an OAuth or permission result code is a credential mismatch. The installation configuration `config :relay, Relay.Channels.Hms, token_url: url, send_url: url, http: opts` replaces the endpoints and the client options.
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Push.Common
  alias Relay.Channels.Push.Content
  alias Relay.Channels.Push.Failures
  alias Relay.Channels.Push.Tokens
  alias Relay.Channels.Push.Ttl
  alias Relay.Channels.Request
  alias Relay.Channels.SettingsCheck

  @token_url "https://oauth-login.cloud.huawei.com/oauth2/v3/token"
  @send_url "https://push-api.cloud.huawei.com/v1/"
  @max_bytes 4096
  @skew 60
  @check_topic "relay-settings-check"
  @check_accepted ~w(80000000 80300007)
  @check_refused ~w(80200001 80200003 80300002)

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
         {:ok, body} <- body(request, push, ttl),
         {:ok, token} <- token(request, settings) do
      call(request, settings, token, body)
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

  # CH-14
  # CH-52
  # TN-30
  @impl Relay.Channels.Adapter
  def check_settings(%{account: account, credentials: credentials, timeout_ms: timeout_ms}) do
    settings = Map.get(account, "settings") || %{}

    with :ok <- SettingsCheck.required(settings, ["app_id", "client_id"]),
         {:ok, secret} <- check_secret(credentials),
         {:ok, token} <- check_token(settings, secret, timeout_ms) do
      validate(settings, token, timeout_ms)
    end
  end

  defp check_secret(nil), do: SettingsCheck.credentials(nil)
  defp check_secret(secret), do: {:ok, secret}

  defp check_token(settings, secret, timeout_ms) do
    case Common.http(__MODULE__, token_request(settings, secret), timeout_ms) do
      {:ok, %{status: 200, body: body}} ->
        access_token(body)

      {:ok, %{status: status}} when status in 400..403 ->
        SettingsCheck.credentials("token_http_" <> Integer.to_string(status))

      {:ok, %{status: status}} ->
        {:error, "token_http_" <> Integer.to_string(status)}

      {:error, reason} ->
        {:error, Atom.to_string(reason)}
    end
  end

  defp access_token(body) do
    case Jason.decode(body) do
      {:ok, %{"access_token" => token}} when is_binary(token) -> {:ok, token}
      _other -> {:error, "token_unexpected_response"}
    end
  end

  defp validate(settings, token, timeout_ms) do
    message = %{"topic" => @check_topic, "data" => "{}"}
    body = Jason.encode!(%{"validate_only" => true, "message" => message})

    case Common.http(__MODULE__, send_request(settings, token, body), timeout_ms) do
      {:ok, %{status: status} = response} -> validated(status, response.body)
      {:error, reason} -> {:error, Atom.to_string(reason)}
    end
  end

  defp validated(status, _body) when status in [401, 403],
    do: SettingsCheck.credentials("http_" <> Integer.to_string(status))

  defp validated(status, body) when status in 200..299 or status == 400 do
    case result_code(body) do
      code when code in @check_accepted -> :ok
      code when code in @check_refused -> SettingsCheck.credentials(code)
      nil -> {:error, "http_" <> Integer.to_string(status)}
      code -> {:error, code}
    end
  end

  defp validated(status, _body), do: {:error, "http_" <> Integer.to_string(status)}

  defp result_code(body) do
    case Jason.decode(body) do
      {:ok, %{"code" => code}} when is_binary(code) -> code
      _other -> nil
    end
  end

  defp ttl(push) do
    case Ttl.fcm(push.expires_at, push.now) do
      {:ok, ttl} -> {:ok, ttl}
      :expired -> {:error, :expired}
    end
  end

  # CH-27
  # CH-33
  # INV-60
  defp body(request, push, ttl) do
    data_message = push.message_class == :system or push.content_free
    urgency = if push.mapping.fcm_priority == :high, do: "HIGH", else: "NORMAL"
    android = %{"urgency" => urgency, "ttl" => ttl}
    android = if data_message, do: android, else: notification(android, request, push)
    data = data(request, push)

    message = %{
      "token" => [Relay.Redacted.expose(request.target.value)],
      "android" => android,
      "data" => Jason.encode!(data)
    }

    body = Jason.encode!(%{"validate_only" => false, "message" => message})

    with :ok <- Content.check(%{"android" => android, "data" => data}), do: size(body)
  end

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

  defp token_request(settings, secret) do
    form = [
      grant_type: "client_credentials",
      client_id: settings["client_id"],
      client_secret: Relay.Redacted.expose(secret)
    ]

    %{
      method: :post,
      url: Common.config(__MODULE__, :token_url, @token_url),
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: URI.encode_query(form, :www_form)
    }
  end

  defp fetch_token(settings, secret, now, timeout_ms) do
    request = token_request(settings, secret)

    with {:ok, %{status: 200, body: body}} <- Common.http(__MODULE__, request, timeout_ms),
         {:ok, %{"access_token" => token, "expires_in" => seconds}} <- Jason.decode(body),
         true <- is_binary(token) and is_integer(seconds) do
      {:ok, %{token: Relay.Redacted.wrap(token), expires_at: now + seconds}}
    else
      _failed -> {:error, :token_unavailable}
    end
  end

  defp send_request(settings, token, body) do
    app = URI.encode(settings["app_id"], &URI.char_unreserved?/1)

    %{
      method: :post,
      url: Common.config(__MODULE__, :send_url, @send_url) <> app <> "/messages:send",
      headers: [
        {"authorization", "Bearer " <> token},
        {"content-type", "application/json; charset=utf-8"}
      ],
      body: body
    }
  end

  defp call(request, settings, token, body) do
    http = send_request(settings, Relay.Redacted.expose(token), body)

    case Common.http(__MODULE__, http, request.timeout_ms) do
      {:ok, response} -> answer(response)
      {:error, :not_sent} -> {:not_sent, "connect_failed"}
      {:error, :uncertain} -> {:uncertain, "no_answer"}
    end
  end

  # CH-32
  defp answer(response) do
    case Failures.read(:hms, response, Relay.Clock.utc_now()) do
      :accepted ->
        id =
          case Jason.decode(response.body) do
            {:ok, %{"requestId" => id}} when is_binary(id) -> id
            _other -> nil
          end

        {:accepted, %{provider_message_id: id}}

      {:rejected, raw} ->
        {:rejected, raw}
    end
  end
end
