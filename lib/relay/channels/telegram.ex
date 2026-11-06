defmodule Relay.Channels.Telegram do
  @moduledoc """
  The Telegram adapter (CH-62, CH-3): the tenant's bot posts with the Bot API's `sendMessage` under its bot token, which is the request's credential; the target is a chat ID. A bot cannot open a conversation: the user starts it first.

  A message about a subject that already has a message in the chat is edited with `editMessageText` (CH-23); an unchanged message is the same message, and a message Telegram can no longer edit is posted again. Telegram gives no delivery or read information; updates arrive at the bot's webhook and are recorded as events only.

  The raw code of a failure is the Bot API `error_code` with the known `description` (`403_bot_blocked` for a user who blocked the bot, `permanent_target`); `429` carries the `retry_after` of the answer; a description that is not known is `http_<error_code>`, which has no mapping and is classified `unknown` (CH-8).

  The settings check calls `getWebhookInfo`: the bot token must still be accepted and the bot's webhook still set, or its updates no longer reach Relay (CH-52).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Messaging
  alias Relay.Channels.ProviderHttp
  alias Relay.Channels.Request
  alias Relay.Channels.SettingsCheck

  @base "https://api.telegram.org/bot"
  @descriptions [
    {"Forbidden: bot was blocked by the user", "403_bot_blocked"},
    {"Forbidden: user is deactivated", "403_user_deactivated"},
    {"Forbidden: bot was kicked", "403_bot_kicked"},
    {"Forbidden: bot can't initiate conversation", "403_cant_initiate"},
    {"Forbidden: bot is not a member", "403_not_member"},
    {"Bad Request: chat not found", "400_chat_not_found"},
    {"Bad Request: message is too long", "400_message_too_long"},
    {"Bad Request: can't parse entities", "400_cant_parse_entities"},
    {"Bad Request: message text is empty", "400_message_text_empty"},
    {"Bad Request: group chat was upgraded", "400_chat_upgraded"},
    {"Bad Request: message to edit not found", "400_message_to_edit_not_found"},
    {"Bad Request: message can't be edited", "400_message_cant_be_edited"},
    {"Bad Request: message is not modified", "400_message_not_modified"}
  ]
  @not_editable ~w(400_message_to_edit_not_found 400_message_cant_be_edited)

  @impl Relay.Channels.Adapter
  def provider, do: "telegram"

  @impl Relay.Channels.Adapter
  def channels, do: ["telegram"]

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

  # CH-52
  # CH-62
  @impl Relay.Channels.Adapter
  def check_settings(%{credentials: credentials, timeout_ms: timeout_ms}) do
    case Messaging.bot_token(credentials) do
      nil ->
        SettingsCheck.credentials(nil)

      token ->
        [method: :post, url: @base <> token <> "/getWebhookInfo", json: %{}]
        |> ProviderHttp.call(timeout_ms)
        |> SettingsCheck.read(&webhook/1)
    end
  end

  defp webhook(%Req.Response{status: 200, body: body}) do
    case Messaging.json(body) do
      %{"ok" => true, "result" => %{"url" => url}} when is_binary(url) and url != "" ->
        :ok

      %{"ok" => true, "result" => %{}} ->
        SettingsCheck.mismatch("webhook_url", "set", nil)

      _other ->
        {:error, "unexpected_response"}
    end
  end

  defp webhook(%Req.Response{status: 404}), do: SettingsCheck.credentials("404_not_found")
  defp webhook(%Req.Response{status: status}), do: {:error, Messaging.http_code(status)}

  defp send_message(request, token, opts) do
    fields = Messaging.fields(request.content)

    case Messaging.split_ref(request.update) do
      {chat, message_id} ->
        body = Map.merge(message(fields), %{"chat_id" => chat, "message_id" => message_id})

        case call(request, token, "editMessageText", body, opts) do
          {:rejected, %{code: "400_message_not_modified"}} ->
            {:accepted, %{provider_message_id: request.update}}

          {:rejected, %{code: code}} when code in @not_editable ->
            post(request, token, fields, opts)

          result ->
            result
        end

      nil ->
        post(request, token, fields, opts)
    end
  end

  defp post(request, token, fields, opts) do
    body = Map.put(message(fields), "chat_id", Messaging.target(request))
    call(request, token, "sendMessage", body, opts)
  end

  # CH-62
  # INV-29
  @doc "The message body of rendered fields: plain text without link previews, and an inline keyboard with one link button when the fields carry one."
  @spec message(Messaging.fields()) :: map()
  def message(fields) do
    base = %{
      "text" => Messaging.text(fields),
      "link_preview_options" => %{"is_disabled" => true}
    }

    case Messaging.link(fields) do
      nil ->
        base

      {label, url} ->
        Map.put(base, "reply_markup", %{
          "inline_keyboard" => [[%{"text" => label, "url" => url}]]
        })
    end
  end

  defp call(request, token, method, body, opts) do
    http = [
      method: :post,
      url: @base <> token <> "/" <> method,
      headers: [{"content-type", "application/json"}],
      body: Jason.encode!(body)
    ]

    case Messaging.send(request, Keyword.merge(http, opts)) do
      {:ok, response} -> result(response.status, response.body)
      {:error, exception} -> Messaging.transport(exception)
    end
  end

  defp result(status, body) do
    case Messaging.json(body) do
      %{"ok" => true, "result" => %{"message_id" => id, "chat" => %{"id" => chat}}}
      when status in 200..299 ->
        {:accepted, %{provider_message_id: "#{chat}:#{id}"}}

      decoded ->
        {:rejected, raw(status, decoded)}
    end
  end

  defp raw(status, decoded) do
    error_code = Map.get(decoded, "error_code", status)
    retry_after_ms = Messaging.seconds_ms(get_in(decoded, ["parameters", "retry_after"]))
    %{code: code(error_code, decoded), status: status, retry_after_ms: retry_after_ms}
  end

  defp code(401, _decoded), do: "401_unauthorized"
  defp code(404, _decoded), do: "404_not_found"
  defp code(429, _decoded), do: "429_too_many_requests"

  defp code(error_code, _decoded) when is_integer(error_code) and error_code >= 500,
    do: Messaging.http_code(error_code)

  defp code(error_code, %{"description" => description}) when is_binary(description) do
    case Enum.find(@descriptions, &String.starts_with?(description, elem(&1, 0))) do
      {_prefix, code} -> code
      nil -> unknown(error_code)
    end
  end

  defp code(error_code, _decoded), do: unknown(error_code)

  defp unknown(error_code) when is_integer(error_code), do: Messaging.http_code(error_code)
  defp unknown(_error_code), do: "http_unknown"

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(%{"status" => status} = response) do
    case result(status, Map.get(response, "body")) do
      {:accepted, _info} -> %{code: "accepted", status: status}
      {:rejected, raw} -> raw
    end
  end
end
