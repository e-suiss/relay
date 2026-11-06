defmodule Relay.Channels.Slack do
  @moduledoc """
  The Slack adapter (CH-62, CH-3): a bot of the tenant's Slack app, installed per workspace with OAuth, posts with the Web API's `chat.postMessage` under the workspace's bot token, which is the request's credential. The target is a conversation or a user ID; a user ID posts to the app's direct message with that user.

  A message about a subject that already has a message in the conversation is edited with `chat.update` (CH-23); when Slack says that message can no longer be edited, a new one is posted. Slack gives no delivery or read information (its capability flags are off); interactions arrive through the Events API and the interactivity endpoint and are recorded as events only.

  The raw code of a failure is Slack's `error` string; `429` is `ratelimited` with Slack's `Retry-After`, and an answer without a Slack error is `http_<status>`.
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Messaging
  alias Relay.Channels.Request

  @base "https://slack.com/api/"
  @not_editable ~w(message_not_found cant_update_message edit_window_closed)

  @impl Relay.Channels.Adapter
  def provider, do: "slack"

  @impl Relay.Channels.Adapter
  def channels, do: ["slack"]

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

  defp send_message(request, token, opts) do
    fields = Messaging.fields(request.content)

    case Messaging.split_ref(request.update) do
      {channel, ts} ->
        body = Map.merge(message(fields), %{"channel" => channel, "ts" => ts})

        case call(request, token, "chat.update", body, opts) do
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
    body =
      fields
      |> message()
      |> Map.merge(%{
        "channel" => Messaging.target(request),
        "unfurl_links" => false,
        "unfurl_media" => false
      })

    call(request, token, "chat.postMessage", body, opts)
  end

  # CH-62
  # INV-29
  @doc "The message body of rendered fields: the text, and a section with a link button when the fields carry one."
  @spec message(Messaging.fields()) :: map()
  def message(fields) do
    text = Messaging.text(fields)

    case Messaging.link(fields) do
      nil ->
        %{"text" => text}

      {label, url} ->
        %{
          "text" => text,
          "blocks" => [
            %{"type" => "section", "text" => %{"type" => "plain_text", "text" => text}},
            %{
              "type" => "actions",
              "elements" => [
                %{
                  "type" => "button",
                  "text" => %{"type" => "plain_text", "text" => label},
                  "url" => url,
                  "action_id" => "relay_link"
                }
              ]
            }
          ]
        }
    end
  end

  defp call(request, token, method, body, opts) do
    http = [
      method: :post,
      url: @base <> method,
      headers: [
        {"authorization", "Bearer " <> token},
        {"content-type", "application/json; charset=utf-8"}
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
      %{"ok" => true, "channel" => channel, "ts" => ts} when status in 200..299 ->
        {:accepted, %{provider_message_id: channel <> ":" <> ts}}

      decoded ->
        {:rejected, raw(status, decoded, retry_after_ms)}
    end
  end

  defp raw(429, _decoded, retry_after_ms),
    do: %{code: "ratelimited", status: 429, retry_after_ms: retry_after_ms}

  defp raw(status, %{"ok" => false, "error" => error}, retry_after_ms) when is_binary(error),
    do: %{code: error, status: status, retry_after_ms: retry_after_ms}

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
