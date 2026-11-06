defmodule Relay.Channels.Push.Override do
  @moduledoc """
  Protection of the policy fields against raw provider overrides (CH-21, INV-16). A request may carry a raw `apns.payload`, `apns.headers`, FCM `android`, `apns` or `webpush`, HMS `android`, Web Push `payload` or WhatsApp block, which is merged deeply into the payload Relay built; the policy fields always keep the policy value: the APNs `interruption-level`, `apns-priority` and `apns-push-type` (also in the FCM `apns` block), the FCM `priority`, Android notification channel and `webpush` `Urgency`, the HMS `urgency`, `importance` and `category`, the Web Push opaque identifier and topic, and the WhatsApp addressing, correlation, message type and template. A conflicting override is not refused: the policy value applies and the overridden path is reported as `override_ignored`. A policy field the policy leaves out stays out.
  """

  @apns_payload [["aps", "interruption-level"]]
  @apns_headers [["apns-priority"], ["apns-push-type"]]
  @android [["priority"], ["notification", "channel_id"]]
  @webpush_headers [["urgency"]]
  @hms_android [["urgency"], ["notification", "importance"], ["category"]]
  @web_push_payload [["relay_id"], ["relay_topic"]]
  @whatsapp [
    ["messaging_product"],
    ["recipient_type"],
    ["to"],
    ["biz_opaque_callback_data"],
    ["type"],
    ["template", "name"],
    ["template", "language"]
  ]

  @typedoc "The merged value and the dotted paths of the ignored override fields."
  @type merged :: {map(), [String.t()]}

  @typedoc "Key paths into a block."
  @type paths :: [[String.t()]]

  @doc "The protected paths, by block."
  @spec protected() :: %{atom() => paths()}
  def protected do
    %{
      apns_payload: @apns_payload,
      apns_headers: @apns_headers,
      android: @android,
      webpush_headers: @webpush_headers,
      hms_android: @hms_android,
      web_push_payload: @web_push_payload,
      whatsapp: @whatsapp
    }
  end

  # CH-21
  @doc "Merges a raw `apns.payload` override into the APNs payload Relay built."
  @spec apns_payload(map(), map() | nil) :: merged()
  def apns_payload(policy, override), do: merge(policy, override, @apns_payload, "apns.payload")

  # CH-21
  @doc "Merges a raw `apns.headers` override into the APNs headers Relay built; header names are compared in lower case."
  @spec apns_headers(map(), map() | nil) :: merged()
  def apns_headers(policy, override), do: headers(policy, override, @apns_headers, "apns.headers")

  defp headers(policy, nil, _paths, _prefix), do: {policy, []}

  defp headers(policy, override, paths, prefix) when is_map(override) do
    override = Map.new(override, fn {name, value} -> {header(name), value} end)
    merge(policy, override, paths, prefix)
  end

  defp header(name), do: name |> to_string() |> String.downcase()

  # CH-21
  @doc "Merges a raw FCM `android` override into the `android` block Relay built."
  @spec android(map(), map() | nil) :: merged()
  def android(policy, override), do: merge(policy, override, @android, "android")

  # CH-21
  @doc "The FCM `apns` block of a raw `fcm.apns` override, which Relay does not build: its `headers` and `payload` keep no APNs policy field; `nil` without an override."
  @spec fcm_apns(map() | nil) :: {map() | nil, [String.t()]}
  def fcm_apns(nil), do: {nil, []}

  def fcm_apns(override) when is_map(override) do
    override = stringify(override)
    {override, h} = part(override, "headers", &headers(&1, &2, @apns_headers, "fcm.apns.headers"))
    {override, p} = part(override, "payload", &merge(&1, &2, @apns_payload, "fcm.apns.payload"))
    {override, h ++ p}
  end

  # CH-21
  @doc "The FCM `webpush` block of a raw `fcm.webpush` override, which Relay does not build: its `headers` carry no `Urgency`; `nil` without an override."
  @spec fcm_webpush(map() | nil) :: {map() | nil, [String.t()]}
  def fcm_webpush(nil), do: {nil, []}

  def fcm_webpush(override) when is_map(override) do
    paths = @webpush_headers
    part(stringify(override), "headers", &headers(&1, &2, paths, "fcm.webpush.headers"))
  end

  defp part(override, key, fun) do
    case override do
      %{^key => %{} = value} ->
        {merged, ignored} = fun.(%{}, value)
        {Map.put(override, key, merged), ignored}

      _none ->
        {override, []}
    end
  end

  # CH-21
  # CH-27
  @doc "Merges a raw HMS `android` override into the `android` block Relay built."
  @spec hms_android(map(), map() | nil) :: merged()
  def hms_android(policy, override), do: merge(policy, override, @hms_android, "hms.android")

  # CH-21
  # CH-23
  @doc "Merges a raw Web Push `payload` override into the classic payload Relay built."
  @spec web_push_payload(map(), map() | nil) :: merged()
  def web_push_payload(policy, override),
    do: merge(policy, override, @web_push_payload, "web_push.payload")

  # API-23
  # CH-60
  # CH-61
  @doc "Merges a raw WhatsApp override into the Cloud API message body Relay built."
  @spec whatsapp(map(), map() | nil) :: merged()
  def whatsapp(policy, override), do: merge(policy, override, @whatsapp, "whatsapp")

  defp merge(policy, nil, _paths, _prefix), do: {policy, []}

  defp merge(policy, override, paths, prefix) when is_map(policy) and is_map(override) do
    merged = deep_merge(policy, stringify(override))

    Enum.reduce(paths, {merged, []}, fn path, {acc, ignored} ->
      case {fetch(policy, path), fetch(acc, path)} do
        {same, same} -> {acc, ignored}
        {{:ok, value}, _other} -> {put(acc, path, value), ignored ++ [dotted(prefix, path)]}
        {:error, _other} -> {delete(acc, path), ignored ++ [dotted(prefix, path)]}
      end
    end)
  end

  defp stringify(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end

  defp fetch(map, [key]) when is_map(map), do: Map.fetch(map, key)

  defp fetch(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, %{} = inner} -> fetch(inner, rest)
      _other -> :error
    end
  end

  defp fetch(_value, _path), do: :error

  defp put(map, [key], value), do: Map.put(map, key, value)

  defp put(map, [key | rest], value) do
    inner = if is_map(map[key]), do: map[key], else: %{}
    Map.put(map, key, put(inner, rest, value))
  end

  defp delete(map, [key]), do: Map.delete(map, key)

  defp delete(map, [key | rest]) do
    case Map.fetch(map, key) do
      {:ok, %{} = inner} -> Map.put(map, key, delete(inner, rest))
      _other -> map
    end
  end

  defp dotted(prefix, path), do: Enum.join([prefix | path], ".")
end
