defmodule Relay.Channels.Push.Fcm do
  @moduledoc """
  FCM HTTP v1 message building (CH-24); the retired legacy and batch endpoints are never used. The `android` block carries the policy values of the priority table and the interruption resolver; a raw `android` override cannot change the FCM `priority` or the notification channel (CH-21) and its ignored paths are returned. The collapse key is the class key of the table, and the subject key travels in the data as `relay_topic` (CH-23).

  A content-free or `system` message is a data message: no notification block, only the opaque `relay_id` and, for a content-free message, the neutral lock screen text the SDK shows when the content cannot be fetched (CH-33, CH-67). Every payload passes the push content check (INV-60) and the 4000-byte FCM limit.
  """

  alias Relay.Channels.Push.Content
  alias Relay.Channels.Push.Interruption
  alias Relay.Channels.Push.Override
  alias Relay.Error

  @endpoint "https://fcm.googleapis.com/v1/projects/"
  @max_bytes 4000
  @priorities %{normal: "NORMAL", high: "HIGH"}
  @category ~r/\A[a-z][a-z0-9_]{0,47}\z/

  @typedoc """
  One message. `fcm_priority` and `collapse_key` come from `Relay.Channels.Push.Priority`, `ttl` from `Relay.Channels.Push.Ttl.fcm/2`, `channel_id` from `android_channel/2`. `notification` takes `title`, `body` and the other Android notification members; `data` the custom data. `data_only: true` (the `system` class) and `content_free` (`id`, `locale`, `lock_screen_body`) make a data message.
  """
  @type message :: %{
          required(:token) => String.t(),
          required(:fcm_priority) => :normal | :high,
          required(:ttl) => String.t(),
          optional(:collapse_key) => String.t() | nil,
          optional(:topic) => String.t() | nil,
          optional(:channel_id) => String.t() | nil,
          optional(:notification) => map() | nil,
          optional(:data) => map(),
          optional(:data_only) => boolean(),
          optional(:content_free) => map() | nil,
          optional(:override_android) => map() | nil
        }

  @type request :: %{
          method: :post,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: String.t()
        }

  # CH-30
  # CH-65 (3)
  @doc "The Android notification channel of a category at an interruption level, which the SDK creates (`relay.<category>.<level>`)."
  @spec android_channel(String.t(), Interruption.level()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def android_channel(category, level) when is_binary(category) do
    if Regex.match?(@category, category),
      do: {:ok, "relay." <> category <> "." <> Interruption.name(level)},
      else: {:error, Error.new(:fcm_channel_invalid, "the category is not a channel name")}
  end

  # CH-24
  # CH-21
  # INV-60
  @doc "Builds the `message` object of one push and the ignored override paths."
  @spec message(message()) :: {:ok, map(), [String.t()]} | {:error, Error.t()}
  def message(%{token: token, fcm_priority: priority, ttl: ttl} = m)
      when is_binary(token) and token != "" and is_map_key(@priorities, priority) do
    with {:ok, data} <- data(m),
         {android, ignored} = android(m, Map.fetch!(@priorities, priority), ttl),
         message = %{"token" => token, "android" => android, "data" => data},
         :ok <- Content.check(message),
         :ok <- size(data, android) do
      {:ok, message, ignored}
    end
  end

  def message(_message),
    do: {:error, Error.new(:fcm_request_invalid, "a token, priority and ttl are required")}

  defp data(m) do
    base =
      if content_free?(m),
        do: content_free_data(m.content_free),
        else: Map.get(m, :data, %{})

    topic = if Map.get(m, :topic), do: %{"relay_topic" => m.topic}, else: %{}
    strings(Map.merge(stringify(base), topic))
  end

  defp content_free_data(content_free) do
    locale = Map.get(content_free, :locale)
    neutral = Content.neutral(locale, Map.get(content_free, :lock_screen_body))

    %{
      "relay_id" => to_string(Map.fetch!(content_free, :id)),
      "relay_neutral_title" => neutral["title"],
      "relay_neutral_body" => neutral["body"]
    }
  end

  defp strings(data) do
    if Enum.all?(data, fn {_key, value} -> is_binary(value) end),
      do: {:ok, data},
      else: {:error, Error.new(:fcm_request_invalid, "FCM data values are strings")}
  end

  defp android(m, priority, ttl) do
    policy =
      %{"priority" => priority, "ttl" => ttl, "collapse_key" => Map.get(m, :collapse_key)}
      |> Map.merge(notification(m))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    cond do
      content_free?(m) and Map.get(m, :override_android) -> {policy, ["android"]}
      content_free?(m) -> {policy, []}
      true -> Override.android(policy, Map.get(m, :override_android))
    end
  end

  defp notification(m) do
    case {data_message?(m), Map.get(m, :notification)} do
      {true, _notification} ->
        %{}

      {false, %{} = notification} ->
        fields = stringify(notification)
        channel = Map.get(m, :channel_id)
        %{"notification" => if(channel, do: Map.put(fields, "channel_id", channel), else: fields)}

      {false, nil} ->
        %{}
    end
  end

  defp data_message?(m), do: content_free?(m) or Map.get(m, :data_only, false) == true

  defp content_free?(m), do: is_map(Map.get(m, :content_free))

  defp size(data, android) do
    notification = Map.get(android, "notification", %{})
    bytes = byte_size(Jason.encode!(data)) + byte_size(Jason.encode!(notification))
    if bytes <= @max_bytes, do: :ok, else: {:error, too_large(bytes)}
  end

  defp too_large(bytes) do
    Error.new(:push_payload_too_large, "the FCM payload is too large", %{
      bytes: bytes,
      limit: @max_bytes
    })
  end

  # CH-24
  @doc "The HTTP v1 send request of a `message` object for `project_id` with an OAuth access token."
  @spec request(String.t(), map(), Relay.Redacted.t()) :: request()
  def request(project_id, %{} = message, %Relay.Redacted{} = access_token)
      when is_binary(project_id) and project_id != "" do
    %{
      method: :post,
      url: @endpoint <> URI.encode(project_id, &URI.char_unreserved?/1) <> "/messages:send",
      headers: [
        {"authorization", "Bearer " <> Relay.Redacted.expose(access_token)},
        {"content-type", "application/json; charset=utf-8"}
      ],
      body: Jason.encode!(%{"message" => message})
    }
  end

  defp stringify(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
