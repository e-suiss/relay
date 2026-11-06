defmodule Relay.Channels.WebPush do
  @moduledoc """
  The Web Push adapter (RFC 8030, RFC 8291, RFC 8292; CH-1, CH-3, CH-26), which needs no provider account of the tenant (CH-5). It encrypts the payload for the subscription with a fresh ephemeral key (`aes128gcm`) and signs the VAPID token of the web application's key in the key store, cached per key and push service (TN-31); it calls the subscription's push service through `Relay.Channels.http_request/1`. UnifiedPush shares this module (`Relay.Channels.UnifiedPush`).

  The push carries the push policy of the channel step only (`Relay.Channels.Push.Policy`): `TTL` from the message's `expires_at`, `Urgency` from the interruption level, never above the class urgency (CH-65 (3)), and `Topic` from the subject (CH-23). There is no silent Web Push: a `system` message is refused (CH-26). A content-free push carries the opaque identifier and neutral text only (CH-33, CH-67). Acceptance (201) is never delivery (CH-32).

  The account settings: `vapid_subject` (`mailto:` or `https:`) and `vapid_keys`, by web application the list of its VAPID keys newest first, each with its key store `label` and base64url `public_key` (C-26, TN-31).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Push.Common
  alias Relay.Channels.Push.Content
  alias Relay.Channels.Push.Failures
  alias Relay.Channels.Push.Interruption
  alias Relay.Channels.Push.Jwt
  alias Relay.Channels.Push.Tokens
  alias Relay.Channels.Push.Ttl
  alias Relay.Channels.Push.WebPush
  alias Relay.Channels.Push.WebPush.Vapid
  alias Relay.Channels.Request

  @renew_before 3_600

  @impl Relay.Channels.Adapter
  def provider, do: "web_push"

  @impl Relay.Channels.Adapter
  def channels, do: ["web_push"]

  # CH-26
  # TN-31
  @impl Relay.Channels.Adapter
  def deliver(%Request{} = request), do: deliver_push(request, __MODULE__, true)

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(response), do: %{code: Failures.code(:web_push, response)}

  # CH-26
  # TN-31
  @doc "Sends one push of a Web Push or UnifiedPush adapter; `vapid?` says whether the account must carry a VAPID identity."
  @spec deliver_push(Request.t(), module(), boolean()) :: Relay.Channels.Adapter.result()
  def deliver_push(%Request{push: %{} = push} = request, adapter, vapid?) do
    with {:ok, keys} <- keys(request),
         {:ok, urgency} <- urgency(push),
         {:ok, ttl} <- ttl(push),
         {:ok, payload} <- payload(request, push),
         {:ok, authorization} <- authorization(request, vapid?),
         subscription = subscription(request, push, keys, payload, {ttl, urgency, authorization}),
         {:ok, built} <- WebPush.request(subscription) do
      call(adapter, built, request.timeout_ms)
    else
      {:error, :expired} -> {:not_sent, "expired"}
      {:error, :signing_unavailable} -> {:not_sent, "auth_unavailable"}
      {:error, reason} -> Common.rejection(reason)
    end
  end

  def deliver_push(%Request{}, _adapter, _vapid?), do: Common.rejection(:not_configured)

  defp keys(request) do
    with keys when keys != nil <- Common.device(request)[:keys],
         %{"p256dh" => p256dh, "auth" => auth} <- Relay.Redacted.expose(keys),
         {:ok, <<4, _::512>> = p256dh} <- Jwt.decode64(p256dh),
         {:ok, <<_::128>> = auth} <- Jwt.decode64(auth) do
      {:ok, %{p256dh: p256dh, auth: auth}}
    else
      _invalid -> {:error, Relay.Error.new(:web_push_keys_invalid, "the subscription keys")}
    end
  end

  # CH-26
  # CH-65 (3)
  defp urgency(push) do
    case Interruption.web_push_urgency(push.level, push.mapping.web_push_urgency) do
      nil -> {:error, Relay.Error.new(:web_push_silent, "Web Push carries no silent message")}
      urgency -> {:ok, urgency}
    end
  end

  defp ttl(push) do
    case Ttl.web_push(push.expires_at, push.now) do
      {:ok, ttl} -> {:ok, ttl}
      :expired -> {:error, :expired}
    end
  end

  # CH-33
  # CH-67
  # INV-60
  defp payload(request, push) do
    base = %{"relay_id" => Common.content_id(request)}
    topic = if push.collapse, do: %{"relay_topic" => push.collapse.topic}, else: %{}

    data =
      if push.content_free,
        do: Map.put(base, "neutral", Content.neutral(push.locale, push.lock_screen_body)),
        else: Map.merge(base, Common.fields(request))

    data = Map.merge(data, topic)

    with :ok <- Content.check(data), do: WebPush.classic(data)
  end

  # TN-31
  defp authorization(request, vapid?) do
    settings = (request.account && request.account["settings"]) || %{}
    app = Common.device(request)[:app]

    case identity(settings, app) do
      {:ok, identity} -> vapid(request, identity)
      :none when not vapid? -> {:ok, nil}
      _missing -> {:error, :not_configured}
    end
  end

  defp identity(%{"vapid_subject" => subject, "vapid_keys" => %{} = keys}, app)
       when is_binary(app) do
    with [_ | _] = listed <- keys[app],
         {:ok, keys} <- vapid_keys(listed),
         {:ok, identity} <- Vapid.identity(subject, keys) do
      {:ok, identity}
    else
      _invalid -> :invalid
    end
  end

  defp identity(_settings, _app), do: :none

  defp vapid_keys(listed) do
    keys =
      for %{"label" => label, "public_key" => public} <- listed,
          is_binary(label),
          {:ok, <<4, _::512>> = point} <- [Jwt.decode64(to_string(public))],
          do: %{label: label, public_key: point}

    if length(keys) == length(listed), do: {:ok, keys}, else: :error
  end

  defp vapid(request, identity) do
    endpoint = Relay.Redacted.expose(request.target.value)
    now = DateTime.to_unix(Relay.Clock.utc_now())

    with {:ok, key} <- Vapid.select_key(identity, nil),
         {:ok, aud} <- Vapid.audience(endpoint) do
      scope = request.scope
      cache_key = {scope.tenant_id, scope.environment, "vapid", key.label, aud}

      signer = fn -> sign(identity, key, endpoint, now) end

      case Tokens.fetch(cache_key, now, @renew_before, signer) do
        {:ok, header} -> {:ok, Relay.Redacted.expose(header)}
        {:error, _error} -> {:error, :signing_unavailable}
      end
    end
  end

  defp sign(identity, key, endpoint, now) do
    case Vapid.authorization(identity, key, endpoint, now, %{}) do
      {:ok, header, cache} ->
        exp = cache |> Map.values() |> Enum.map(& &1.exp) |> Enum.max()
        {:ok, %{token: Relay.Redacted.wrap(header), expires_at: exp}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp subscription(request, push, keys, payload, {ttl, urgency, authorization}) do
    %{
      endpoint: Relay.Redacted.expose(request.target.value),
      p256dh: keys.p256dh,
      auth: keys.auth,
      payload: payload,
      ttl: ttl,
      urgency: urgency,
      authorization: authorization,
      topic: push.collapse && push.collapse.web_push
    }
  end

  # CH-32
  defp call(adapter, built, timeout_ms) do
    case Common.http(adapter, built, timeout_ms) do
      {:ok, response} ->
        case Failures.read(:web_push, response, Relay.Clock.utc_now()) do
          :accepted ->
            location = List.keyfind(response.headers, "location", 0)
            {:accepted, %{provider_message_id: location && elem(location, 1)}}

          {:rejected, raw} ->
            {:rejected, raw}
        end

      {:error, :not_sent} ->
        {:not_sent, "connect_failed"}

      {:error, :uncertain} ->
        {:uncertain, "no_answer"}
    end
  end
end
