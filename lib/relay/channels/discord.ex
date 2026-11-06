defmodule Relay.Channels.Discord do
  @moduledoc """
  The Discord adapter (CH-62, CH-3): the bot of the tenant's Discord application, added to a server with OAuth, posts with the REST API's create message under its bot token, which is the request's credential. The target is a channel ID, or `user:<id>` for a direct message, whose channel is opened first (`POST /users/@me/channels`).

  The message carries a `nonce` derived from the provider idempotency key with `enforce_nonce`, so Discord itself drops a second create of the same send (INV-13). Mentions are never parsed. A message about a subject that already has a message in the channel is edited (CH-23); a message Discord no longer knows is posted again. Discord gives no delivery or read information; interactions arrive at the application's interactions endpoint and are recorded as events only.

  The raw code of a failure is Discord's JSON error `code`; `429` carries Discord's `retry_after`, and an answer without a Discord error code is `http_<status>`.

  The settings check reads the bot's own user (`GET /users/@me`): the bot token must still be accepted (CH-14, CH-52).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Messaging
  alias Relay.Channels.ProviderHttp
  alias Relay.Channels.Request
  alias Relay.Channels.SettingsCheck

  @base "https://discord.com/api/v10"
  @nonce_length 25

  @impl Relay.Channels.Adapter
  def provider, do: "discord"

  @impl Relay.Channels.Adapter
  def channels, do: ["discord"]

  @impl Relay.Channels.Adapter
  def deliver(%Request{} = request), do: deliver(request, [])

  # CH-62
  # CH-23
  @doc "Delivers a request with extra HTTP client options; see `c:Relay.Channels.Adapter.deliver/1`."
  @spec deliver(Request.t(), keyword()) :: Relay.Channels.Adapter.result()
  def deliver(%Request{} = request, opts) do
    case Messaging.token(request) do
      nil -> {:rejected, %{code: "credential_missing", status: nil}}
      token -> send_message(request, token, opts)
    end
  end

  # CH-14
  # CH-52
  @impl Relay.Channels.Adapter
  def check_settings(%{credentials: credentials, timeout_ms: timeout_ms}) do
    case Messaging.bot_token(credentials) do
      nil ->
        SettingsCheck.credentials(nil)

      token ->
        [method: :get, url: @base <> "/users/@me", headers: [{"authorization", "Bot " <> token}]]
        |> ProviderHttp.call(timeout_ms)
        |> SettingsCheck.read(&me/1)
    end
  end

  defp me(%Req.Response{status: 200}), do: :ok
  defp me(%Req.Response{status: status}), do: {:error, Messaging.http_code(status)}

  defp send_message(request, token, opts) do
    fields = Messaging.fields(request.content)

    case Messaging.split_ref(request.update) do
      {channel, message_id} ->
        path = "/channels/" <> channel <> "/messages/" <> message_id

        case call(request, token, :patch, path, message(fields), opts) do
          {:rejected, %{code: "10008"}} -> post(request, token, fields, opts)
          result -> result
        end

      nil ->
        post(request, token, fields, opts)
    end
  end

  defp post(request, token, fields, opts) do
    with {:ok, channel} <- channel(request, token, opts) do
      body =
        fields
        |> message()
        |> Map.merge(%{"nonce" => nonce(request.idempotency_key), "enforce_nonce" => true})

      call(request, token, :post, "/channels/" <> channel <> "/messages", body, opts)
    end
  end

  defp channel(request, token, opts) do
    case Messaging.target(request) do
      "user:" <> user ->
        body = %{"recipient_id" => user}

        case call(request, token, :post, "/users/@me/channels", body, opts) do
          {:accepted, %{provider_message_id: channel}} -> {:ok, channel}
          other -> other
        end

      channel ->
        {:ok, channel}
    end
  end

  # INV-13
  @doc "The Discord `nonce` of a provider idempotency key: 25 URL-safe characters of its SHA-256."
  @spec nonce(String.t()) :: String.t()
  def nonce(key) when is_binary(key) do
    :sha256
    |> :crypto.hash(key)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, @nonce_length)
  end

  # CH-62
  # INV-29
  @doc "The message body of rendered fields: the content without mention parsing, and one link button when the fields carry one."
  @spec message(Messaging.fields()) :: map()
  def message(fields) do
    base = %{"content" => Messaging.text(fields), "allowed_mentions" => %{"parse" => []}}

    case Messaging.link(fields) do
      nil ->
        base

      {label, url} ->
        button = %{"type" => 2, "style" => 5, "label" => label, "url" => url}
        Map.put(base, "components", [%{"type" => 1, "components" => [button]}])
    end
  end

  defp call(request, token, method, path, body, opts) do
    http = [
      method: method,
      url: @base <> path,
      headers: [
        {"authorization", "Bot " <> token},
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
      %{"id" => id, "channel_id" => channel} when status in 200..299 ->
        {:accepted, %{provider_message_id: channel <> ":" <> id}}

      %{"id" => id} when status in 200..299 ->
        {:accepted, %{provider_message_id: id}}

      decoded ->
        {:rejected, raw(status, decoded, retry_after_ms)}
    end
  end

  defp raw(429, decoded, retry_after_ms) do
    wait = Messaging.seconds_ms(Map.get(decoded, "retry_after")) || retry_after_ms

    case Map.get(decoded, "code") do
      code when is_integer(code) and code > 0 ->
        %{code: Integer.to_string(code), status: 429, retry_after_ms: wait}

      _none ->
        %{code: "http_429", status: 429, retry_after_ms: wait}
    end
  end

  defp raw(status, %{"code" => code}, retry_after_ms) when is_integer(code) and code > 0,
    do: %{code: Integer.to_string(code), status: status, retry_after_ms: retry_after_ms}

  defp raw(status, _decoded, retry_after_ms),
    do: %{code: Messaging.http_code(status), status: status, retry_after_ms: retry_after_ms}

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(%{"status" => status} = response) do
    retry_after_ms = Messaging.vector_retry_after_ms(response)

    case result(status, Map.get(response, "body"), retry_after_ms) do
      {:accepted, _info} -> %{code: "accepted", status: status}
      {:rejected, raw} -> raw
    end
  end
end
