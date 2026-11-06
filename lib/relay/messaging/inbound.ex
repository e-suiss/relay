defmodule Relay.Messaging.Inbound do
  @moduledoc """
  Inbound interactions of the messaging channels (CH-62, WH-49): the provider's signature on the raw body, before anything is parsed, and the provider event read from the body.

    * Slack: the `v0` signature (`X-Slack-Signature`, `X-Slack-Request-Timestamp`) under the app's signing secret; Events API callbacks (deduplicated by `event_id`), the URL verification challenge, and interactivity payloads (form encoded, deduplicated by the body's digest).
    * Telegram: the webhook's secret token (`X-Telegram-Bot-Api-Secret-Token`), a compensating control whose authenticity is unverifiable (§12.1.2); updates are deduplicated by `update_id`.
    * Discord: the Ed25519 signature (`X-Signature-Ed25519` over `X-Signature-Timestamp` and the body) under the application's public key; the `PING` is answered, interactions are deduplicated by their `id`.
    * Teams: the Bot Framework JWT is verified by the caller (`Relay.Messaging`); activities are deduplicated by their `id`.

  A parsed event names what happened (`message`, `action`, `command`, `conversation` or `membership`), the workspace, the provider user, the conversation and, when the event refers to a message Relay sent, that message's provider reference. A card button and an inline reply are never an approval: an interaction is recorded as an event only, and an approval is given only on the Access approval surface (CH-62, INV-29, AG-32).
  """

  alias Relay.Messaging.Install
  alias Relay.Redacted

  @type headers :: [{String.t(), String.t()}]
  @type event :: %{
          required(:event_id) => String.t(),
          required(:kind) => String.t(),
          optional(:workspace) => String.t() | nil,
          optional(:user) => String.t() | nil,
          optional(:conversation) => String.t() | nil,
          optional(:message_ref) => String.t() | nil,
          optional(:action) => String.t() | nil,
          optional(:text) => String.t() | nil,
          optional(:reference) => map() | nil
        }
  @type parsed :: {:reply, map()} | {:event, event(), map() | nil} | :ignored

  @max_text 4000

  # CH-62
  # T-40
  @doc "Verifies a Slack, Telegram or Discord request on its raw body with the channel identity's secret, at `now`."
  @spec verify(String.t(), Redacted.t(), binary(), headers(), DateTime.t()) ::
          :ok | {:error, atom()}
  def verify("slack", secret, raw, headers, now) do
    key = Redacted.wrap(field(secret, "signing_secret"))
    Relay.Channels.verify_slack(key, raw, headers, now)
  end

  def verify("telegram", secret, _raw, headers, _now) do
    token = Install.telegram_secret(%{secret: secret})
    Relay.Channels.verify_secret_token(token, headers, "x-telegram-bot-api-secret-token")
  end

  def verify("discord", secret, raw, headers, now) do
    case Base.decode16(field(secret, "public_key"), case: :mixed) do
      {:ok, <<_::256>> = public} ->
        opts = [header: "x-signature-ed25519", timestamp_header: "x-signature-timestamp"]
        Relay.Channels.verify_ed25519(Redacted.wrap(public), raw, headers, [now: now] ++ opts)

      _invalid ->
        {:error, :bad_signature}
    end
  end

  def verify(_channel, _secret, _raw, _headers, _now), do: {:error, :bad_signature}

  defp field(secret, name), do: Install.field(secret, name)

  # CH-62
  # WH-49
  @doc "Reads a verified request body: an immediate reply without an event, an event with the reply the provider expects, or `:ignored`."
  @spec parse(String.t(), binary(), String.t() | nil) :: parsed()
  def parse("slack", raw, "application/x-www-form-urlencoded") do
    with %{"payload" => payload} <- URI.decode_query(raw),
         {:ok, %{} = p} <- Jason.decode(payload) do
      {:event, slack_action(p, digest(raw)), nil}
    else
      _invalid -> :ignored
    end
  end

  def parse("slack", raw, _type) do
    case json(raw) do
      %{"type" => "url_verification", "challenge" => challenge} when is_binary(challenge) ->
        {:reply, %{"challenge" => challenge}}

      %{"type" => "event_callback", "event_id" => id, "event" => %{} = event} = body
      when is_binary(id) ->
        {:event, slack_event(id, body["team_id"], event), nil}

      _other ->
        :ignored
    end
  end

  def parse("telegram", raw, _type) do
    case json(raw) do
      %{"update_id" => id} = update when is_integer(id) ->
        {:event, telegram(Integer.to_string(id), update), nil}

      _other ->
        :ignored
    end
  end

  def parse("discord", raw, _type) do
    case json(raw) do
      %{"type" => 1} ->
        {:reply, %{"type" => 1}}

      %{"type" => 3, "id" => id} = i when is_binary(id) ->
        {:event, discord(id, "action", i), %{"type" => 6}}

      %{"type" => type, "id" => id} = i when is_binary(id) and type in [2, 4, 5] ->
        reply = %{"type" => 4, "data" => %{"content" => "Received.", "flags" => 64}}
        {:event, discord(id, "command", i), reply}

      _other ->
        :ignored
    end
  end

  def parse("teams", raw, _type) do
    case json(raw) do
      %{"id" => id, "type" => type} = activity when is_binary(id) and is_binary(type) ->
        {:event, teams(id, type, activity), teams_reply(activity)}

      _other ->
        :ignored
    end
  end

  def parse(_channel, _raw, _type), do: :ignored

  defp slack_action(p, digest) do
    channel = get_in(p, ["channel", "id"]) || get_in(p, ["container", "channel_id"])
    ts = get_in(p, ["container", "message_ts"]) || get_in(p, ["message", "ts"])
    [action | _] = list(p["actions"]) ++ [%{}]

    %{
      event_id: "body:" <> digest,
      kind: "action",
      workspace: get_in(p, ["team", "id"]),
      user: get_in(p, ["user", "id"]),
      conversation: channel,
      message_ref: ref(channel, ts),
      action: action["action_id"],
      text: nil
    }
  end

  defp slack_event(id, team, event) do
    channel = event["channel"]

    %{
      event_id: id,
      kind: if(event["type"] == "message", do: "message", else: "conversation"),
      workspace: team,
      user: event["user"],
      conversation: channel,
      message_ref: ref(channel, event["thread_ts"]),
      action: event["type"],
      text: text(event["text"])
    }
  end

  defp telegram(id, %{"callback_query" => %{} = q}) do
    message = q["message"] || %{}
    chat = stringify(get_in(message, ["chat", "id"]))

    %{
      event_id: id,
      kind: "action",
      user: stringify(get_in(q, ["from", "id"])),
      conversation: chat,
      message_ref: ref(chat, stringify(message["message_id"])),
      action: q["data"],
      text: nil
    }
  end

  defp telegram(id, %{"my_chat_member" => %{} = m}) do
    %{
      event_id: id,
      kind: "membership",
      user: stringify(get_in(m, ["from", "id"])),
      conversation: stringify(get_in(m, ["chat", "id"])),
      action: get_in(m, ["new_chat_member", "status"]),
      text: nil
    }
  end

  defp telegram(id, update) do
    message = update["message"] || update["edited_message"] || %{}
    chat = stringify(get_in(message, ["chat", "id"]))
    reply = stringify(get_in(message, ["reply_to_message", "message_id"]))

    %{
      event_id: id,
      kind: "message",
      user: stringify(get_in(message, ["from", "id"])),
      conversation: chat,
      message_ref: ref(chat, reply),
      action: nil,
      text: text(message["text"])
    }
  end

  defp discord(id, kind, i) do
    message = i["message"] || %{}
    user = get_in(i, ["member", "user", "id"]) || get_in(i, ["user", "id"])

    %{
      event_id: id,
      kind: kind,
      workspace: i["guild_id"],
      user: user,
      conversation: i["channel_id"],
      message_ref: ref(message["channel_id"], message["id"]),
      action: get_in(i, ["data", "custom_id"]) || get_in(i, ["data", "name"]),
      text: nil
    }
  end

  defp teams(id, type, activity) do
    conversation = get_in(activity, ["conversation", "id"])

    %{
      event_id: id,
      kind: teams_kind(type),
      workspace: get_in(activity, ["channelData", "tenant", "id"]),
      user: get_in(activity, ["from", "aadObjectId"]) || get_in(activity, ["from", "id"]),
      conversation: conversation,
      message_ref: activity["replyToId"],
      action: activity["name"] || type,
      text: text(activity["text"]),
      reference: reference(activity["serviceUrl"], conversation)
    }
  end

  defp teams_kind("message"), do: "message"
  defp teams_kind("invoke"), do: "action"
  defp teams_kind(_type), do: "conversation"

  defp reference(url, conversation) when is_binary(url) and is_binary(conversation),
    do: %{"service_url" => url, "conversation_id" => conversation}

  defp reference(_url, _conversation), do: nil

  defp teams_reply(%{"type" => "invoke", "name" => "adaptiveCard/action"}) do
    %{
      "statusCode" => 200,
      "type" => "application/vnd.microsoft.activity.message",
      "value" => "Received."
    }
  end

  defp teams_reply(_activity), do: nil

  defp ref(conversation, message) when is_binary(conversation) and is_binary(message),
    do: conversation <> ":" <> message

  defp ref(_conversation, _message), do: nil

  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(_value), do: nil

  defp text(value) when is_binary(value), do: String.slice(value, 0, @max_text)
  defp text(_value), do: nil

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp json(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = decoded} -> decoded
      _invalid -> %{}
    end
  end

  @doc "The hex SHA-256 of a raw body."
  @spec digest(binary()) :: String.t()
  def digest(raw), do: :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)
end
