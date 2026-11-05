defmodule Relay.Channels.Push.Apns do
  @moduledoc """
  APNs request building (CH-24): every `apns-push-type`, broadcast push to a channel (`apns-channel-id`) and Live Activity push-to-start. The request carries the policy values of the priority table and the interruption resolver; a raw override cannot change them (CH-21) and its ignored paths are returned. A content-free notification carries neutral text, `mutable-content` and the opaque notification identifier only, and drops any raw payload override (CH-33, CH-67). Every payload passes the push content check (INV-60) and the size limit (4096 bytes, 5120 for VoIP); a payload over the limit is refused, never cut.

  The `authorization` header is the adapter's: `bearer <provider token>` from `Relay.Channels.Push.Apns.Credentials`.
  """

  alias Relay.Channels.Push.Content
  alias Relay.Channels.Push.Interruption
  alias Relay.Channels.Push.Override
  alias Relay.Error

  @push_types ~w(alert background location voip complication fileprovider mdm liveactivity pushtotalk widgets controls)a
  @suffix %{
    voip: ".voip",
    complication: ".complication",
    fileprovider: ".pushkit.fileprovider",
    liveactivity: ".push-type.liveactivity",
    location: ".location-query",
    pushtotalk: ".voip-ptt",
    widgets: ".push-type.widgets",
    controls: ".push-type.controls"
  }
  @silent [:background, :fileprovider, :mdm, :location, :widgets, :controls]
  @events %{start: "start", update: "update", end: "end"}
  @device_token ~r/\A[0-9a-fA-F]{64,200}\z/
  @max_bytes 4096
  @voip_bytes 5120

  @type push_type ::
          :alert
          | :background
          | :location
          | :voip
          | :complication
          | :fileprovider
          | :mdm
          | :liveactivity
          | :pushtotalk
          | :widgets
          | :controls

  @typedoc """
  One notification. `device_token` (hex) addresses a device; `channel_id` addresses a broadcast channel and needs the `liveactivity` push type. `apns_priority` and `interruption_level` come from `Relay.Channels.Push.Priority` and `Relay.Channels.Push.Interruption`, `expiration` from `Relay.Channels.Push.Ttl.apns_expiration/2`, `collapse_id` from `Relay.Channels.Push.Collapse`. `aps` holds the other `aps` members (`alert`, `badge`, `sound`, `thread-id`, `category`, `relevance-score`, `target-content-id`, …) and `data` the custom top-level members. `live_activity` takes `event` (`:start`, `:update`, `:end`), `timestamp`, `content_state` and, for `:start`, `attributes_type` and `attributes`, with optional `dismissal_date`, `stale_date` and `input_push_token`. `content_free` takes the opaque `id`, the `locale` and the template's `lock_screen_body`.
  """
  @type notification :: %{
          required(:push_type) => push_type(),
          required(:bundle_id) => String.t(),
          required(:apns_id) => binary(),
          required(:apns_priority) => 1 | 5 | 10,
          optional(:device_token) => String.t(),
          optional(:channel_id) => String.t(),
          optional(:topic) => String.t(),
          optional(:interruption_level) => Interruption.level() | nil,
          optional(:collapse_id) => String.t() | nil,
          optional(:expiration) => non_neg_integer() | nil,
          optional(:aps) => map(),
          optional(:data) => map(),
          optional(:live_activity) => map() | nil,
          optional(:content_free) => map() | nil,
          optional(:override_payload) => map() | nil,
          optional(:override_headers) => map() | nil
        }

  @type request :: %{
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: String.t(),
          override_ignored: [String.t()]
        }

  @doc "The push types."
  @spec push_types() :: [push_type(), ...]
  def push_types, do: @push_types

  # CH-24
  @doc "The `apns-topic` of a push type: the bundle identifier with the type's suffix; an MDM push takes its topic from the notification."
  @spec topic(push_type(), String.t()) :: String.t()
  def topic(push_type, bundle_id) when push_type in @push_types and is_binary(bundle_id),
    do: bundle_id <> Map.get(@suffix, push_type, "")

  # CH-24
  # CH-21
  # INV-60
  @doc "Builds the request of one notification."
  @spec request(notification()) :: {:ok, request()} | {:error, Error.t()}
  def request(%{push_type: type, bundle_id: bundle, apns_id: apns_id} = n)
      when type in @push_types and is_binary(bundle) do
    with {:ok, path, target} <- path(n),
         {:ok, id} <- apns_id(apns_id),
         {:ok, aps} <- aps(n),
         {:ok, collapse} <- collapse(Map.get(n, :collapse_id)),
         {payload, ignored_payload} = payload(n, aps),
         body = Jason.encode!(payload),
         :ok <- Content.check(payload),
         :ok <- size(type, body) do
      {headers, ignored_headers} = headers(n, id, target, collapse)
      ignored = ignored_payload ++ ignored_headers
      {:ok, %{path: path, headers: headers, body: body, override_ignored: ignored}}
    end
  end

  def request(_notification),
    do: {:error, Error.new(:apns_request_invalid, "unknown push type or missing bundle")}

  defp path(%{channel_id: channel, push_type: :liveactivity, bundle_id: bundle})
       when is_binary(channel) and channel != "",
       do: {:ok, "/4/broadcasts/apps/" <> bundle, [{"apns-channel-id", channel}]}

  defp path(%{channel_id: channel}) when is_binary(channel),
    do: {:error, Error.new(:apns_request_invalid, "broadcast needs the liveactivity push type")}

  defp path(%{device_token: token}) when is_binary(token) do
    if Regex.match?(@device_token, token),
      do: {:ok, "/3/device/" <> String.downcase(token), []},
      else: {:error, Error.new(:apns_request_invalid, "the device token is not hexadecimal")}
  end

  defp path(_notification),
    do: {:error, Error.new(:apns_request_invalid, "a device token or channel is required")}

  defp apns_id(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>) do
    {:ok, Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))}
  end

  defp apns_id(<<_::288>> = text) do
    if Regex.match?(~r/\A[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i, text),
      do: {:ok, String.downcase(text)},
      else: {:error, Error.new(:apns_request_invalid, "apns-id is a UUID")}
  end

  defp apns_id(_id), do: {:error, Error.new(:apns_request_invalid, "apns-id is a UUID")}

  defp collapse(nil), do: {:ok, nil}

  defp collapse(id) when is_binary(id) and byte_size(id) in 1..64, do: {:ok, id}

  defp collapse(_id),
    do: {:error, Error.new(:apns_request_invalid, "apns-collapse-id is 1 to 64 bytes")}

  defp aps(%{push_type: type} = n) do
    aps = n |> Map.get(:aps, %{}) |> stringify()

    aps =
      cond do
        content_free?(n) -> content_free_aps(aps, n.content_free)
        type in @silent -> aps |> Map.drop(["alert", "sound", "badge"]) |> silent(type)
        true -> aps
      end

    with {:ok, aps} <- live_activity(aps, n),
         do: {:ok, level(aps, type, Map.get(n, :interruption_level))}
  end

  defp silent(aps, :background), do: Map.put(aps, "content-available", 1)
  defp silent(aps, _type), do: aps

  defp content_free?(n), do: is_map(Map.get(n, :content_free))

  defp content_free_aps(aps, content_free) do
    locale = Map.get(content_free, :locale)
    alert = Content.neutral(locale, Map.get(content_free, :lock_screen_body))

    aps
    |> Map.take(["sound", "thread-id", "category", "badge"])
    |> Map.merge(%{"alert" => alert, "mutable-content" => 1})
  end

  defp level(aps, type, level) when type in @silent or is_nil(level),
    do: Map.delete(aps, "interruption-level")

  defp level(aps, _type, level), do: Map.put(aps, "interruption-level", Interruption.name(level))

  defp live_activity(aps, %{push_type: :liveactivity, live_activity: %{event: event} = la})
       when is_map_key(@events, event) do
    with :ok <- start_fields(event, la),
         {:ok, timestamp} <- integer(Map.get(la, :timestamp), "timestamp") do
      fields =
        [
          {"event", Map.fetch!(@events, event)},
          {"timestamp", timestamp},
          {"content-state", Map.get(la, :content_state)},
          {"attributes-type", Map.get(la, :attributes_type)},
          {"attributes", Map.get(la, :attributes)},
          {"dismissal-date", Map.get(la, :dismissal_date)},
          {"stale-date", Map.get(la, :stale_date)},
          {"input-push-token", if(Map.get(la, :input_push_token), do: 1)}
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      {:ok, Map.merge(aps, stringify(fields))}
    end
  end

  defp live_activity(_aps, %{push_type: :liveactivity}),
    do: {:error, Error.new(:apns_request_invalid, "a Live Activity push needs its event")}

  defp live_activity(aps, _n), do: {:ok, aps}

  defp start_fields(:start, la) do
    if is_binary(Map.get(la, :attributes_type)) and is_map(Map.get(la, :attributes)),
      do: :ok,
      else: {:error, Error.new(:apns_request_invalid, "push-to-start needs attributes")}
  end

  defp start_fields(_event, _la), do: :ok

  defp integer(value, _name) when is_integer(value) and value >= 0, do: {:ok, value}

  defp integer(_value, name),
    do: {:error, Error.new(:apns_request_invalid, "#{name} is Unix seconds")}

  defp payload(n, aps) do
    if content_free?(n) do
      ignored = if Map.get(n, :override_payload), do: ["apns.payload"], else: []
      {%{"aps" => aps, "relay" => %{"id" => to_string(n.content_free.id)}}, ignored}
    else
      data = n |> Map.get(:data, %{}) |> stringify() |> Map.delete("aps")
      Override.apns_payload(Map.put(data, "aps", aps), Map.get(n, :override_payload))
    end
  end

  defp headers(n, id, target, collapse) do
    priority = if n.push_type == :background, do: 5, else: n.apns_priority

    policy =
      %{
        "apns-push-type" => Atom.to_string(n.push_type),
        "apns-topic" => Map.get(n, :topic) || topic(n.push_type, n.bundle_id),
        "apns-priority" => Integer.to_string(priority),
        "apns-id" => id,
        "apns-expiration" => expiration(Map.get(n, :expiration)),
        "apns-collapse-id" => collapse
      }
      |> Map.merge(Map.new(target))
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Map.new()

    {headers, ignored} = Override.apns_headers(policy, Map.get(n, :override_headers))
    {headers |> Enum.map(fn {k, v} -> {k, to_string(v)} end) |> Enum.sort(), ignored}
  end

  defp expiration(nil), do: nil
  defp expiration(at) when is_integer(at) and at >= 0, do: Integer.to_string(at)

  defp size(type, body) do
    limit = if type == :voip, do: @voip_bytes, else: @max_bytes

    if byte_size(body) <= limit, do: :ok, else: {:error, too_large(byte_size(body), limit)}
  end

  defp too_large(bytes, limit) do
    Error.new(:push_payload_too_large, "the APNs payload is too large", %{
      bytes: bytes,
      limit: limit
    })
  end

  defp stringify(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
