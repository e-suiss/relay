defmodule Relay.Channels.Apns do
  @moduledoc """
  The APNs adapter (CH-1, CH-24, CH-25). It sends one notification to one device token over Relay's own HTTP/2 client (`Relay.Channels.Push.H2`) with token authentication: the provider JWT is signed in the key store for the account's team and key and kept per connection (`Relay.Channels.Apns.Bearer`, TN-28, TN-29). A connection serves one tenant environment, one APNs environment (`production` or `sandbox`, from the device) and one team key (INV-40).

  The request carries the push policy of the channel step only (`Relay.Channels.Push.Policy`): `apns-priority`, the push type, the interruption level, `apns-collapse-id`, `apns-expiration` from the message's `expires_at`, and the content-free form with neutral text; a raw `apns.payload` or `apns.headers` override cannot change a policy field and its ignored paths are reported (CH-21). `apns-id` is the delivery identifier. APNs gives no delivery receipt: acceptance is never delivery (CH-32).

  The account settings: `team_id`, `key_id`, `key_label` (the key store label of the `.p8` key), `bundle_id` and optionally `token_refresh_s` (1200 to 3600).

  The settings check signs a new provider token in the key store and sends a background push for the bundle to a well-formed device token no device holds, on the production host: APNs checks the token and the topic before the device, so `BadDeviceToken` says the team, key and bundle hold and nothing is delivered; `403` (`InvalidProviderToken`, `ExpiredProviderToken`) is a credential mismatch and a refused topic a `bundle_id` mismatch (CH-14, CH-52). The installation configuration `config :relay, Relay.Channels.Apns, origins: %{"production" => origin, "sandbox" => origin}, connection: opts` replaces the APNs hosts and the connection options.
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Push.Apns
  alias Relay.Channels.Push.Apns.Token
  alias Relay.Channels.Push.Common
  alias Relay.Channels.Push.Failures
  alias Relay.Channels.Push.H2
  alias Relay.Channels.Push.Ttl
  alias Relay.Channels.Request
  alias Relay.Channels.SettingsCheck

  @origins %{
    "production" => {:https, "api.push.apple.com", 443},
    "sandbox" => {:https, "api.sandbox.push.apple.com", 443}
  }
  @settings ~w(team_id key_id key_label bundle_id)
  @check_device String.duplicate("0", 64)
  @topic_refused ~w(BadTopic TopicDisallowed MissingTopic)

  @impl Relay.Channels.Adapter
  def provider, do: "apns"

  @impl Relay.Channels.Adapter
  def channels, do: ["push"]

  # CH-24
  # CH-25
  # INV-40
  @impl Relay.Channels.Adapter
  def deliver(%Request{push: %{} = push} = request) do
    with {:ok, settings} <- Common.settings(request, @settings),
         {:ok, origin} <- origin(request),
         {:ok, notification} <- notification(request, settings, push),
         {:ok, built} <- Apns.request(notification) do
      call(request, settings, origin, built, notification)
    else
      {:error, :expired} -> {:not_sent, "expired"}
      {:error, reason} -> Common.rejection(reason)
    end
  end

  def deliver(%Request{}), do: Common.rejection(:not_configured)

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(response), do: %{code: Failures.code(:apns, response)}

  # CH-14
  # CH-52
  # TN-29
  @impl Relay.Channels.Adapter
  def check_settings(%{account: account, timeout_ms: timeout_ms}) do
    settings = Map.get(account, "settings") || %{}

    with :ok <- SettingsCheck.required(settings, @settings) do
      now = DateTime.to_unix(Relay.Clock.utc_now())
      token = Token.new(settings["team_id"], settings["key_id"], settings["key_label"])

      case Token.current(token, now) do
        {:ok, jwt, _state} -> probe(account, settings, jwt, timeout_ms)
        {:error, error, _state} -> SettingsCheck.key_store(error, "key_label")
      end
    end
  end

  defp probe(account, settings, jwt, timeout_ms) do
    origins = Common.config(__MODULE__, :origins, @origins)
    origin = Map.get(origins, "production")

    key =
      {account["environment"], "apns", origin, settings["team_id"], settings["key_id"], :check}

    h2 = %{
      method: "POST",
      path: "/3/device/" <> @check_device,
      headers: [
        {"authorization", "bearer " <> jwt},
        {"apns-topic", settings["bundle_id"]},
        {"apns-push-type", "background"},
        {"apns-priority", "5"},
        {"content-type", "application/json"}
      ],
      body: ~s({"aps":{"content-available":1}})
    }

    opts = Common.config(__MODULE__, :connection, [])

    case H2.request(account["tenant_id"], key, origin, nil, h2, timeout_ms, opts) do
      {:ok, response} -> checked(response, settings["bundle_id"])
      {_transport, reason} -> {:error, reason}
    end
  end

  defp checked(%{status: status, body: body}, bundle) do
    code = Failures.code(:apns, %{"status" => status, "body" => body})

    case {status, code} do
      {200, _code} -> :ok
      {400, "400/BadDeviceToken"} -> :ok
      {400, "400/" <> reason} when reason in @topic_refused -> topic(bundle, reason)
      {403, _code} -> SettingsCheck.credentials(code)
      {_status, _code} -> {:error, code}
    end
  end

  defp topic(bundle, reason), do: SettingsCheck.mismatch("bundle_id", bundle, reason)

  defp origin(request) do
    origins = Common.config(__MODULE__, :origins, @origins)

    case Map.fetch(origins, Common.device(request)[:apns_environment]) do
      {:ok, origin} -> {:ok, origin}
      :error -> {:error, :not_configured}
    end
  end

  defp notification(request, settings, push) do
    with {:ok, expiration} <- expiration(push) do
      type = if push.message_class == :system, do: :background, else: push.mapping.apns_push_type

      notification = %{
        push_type: type,
        bundle_id: settings["bundle_id"],
        apns_id: request.delivery_id,
        apns_priority: push.mapping.apns_priority,
        device_token: Relay.Redacted.expose(request.target.value),
        interruption_level: push.level,
        collapse_id: push.collapse && push.collapse.apns,
        expiration: expiration,
        aps: aps(request, push, type),
        data: data(request, push),
        content_free: content_free(request, push, type),
        override_payload: Common.override(request, "apns", "payload"),
        override_headers: Common.override(request, "apns", "headers")
      }

      {:ok, notification}
    end
  end

  defp expiration(push) do
    case Ttl.apns_expiration(push.expires_at, push.now) do
      {:ok, at} -> {:ok, at}
      :expired -> {:error, :expired}
    end
  end

  defp aps(_request, _push, :background), do: %{}

  defp aps(request, push, _type) do
    %{"alert" => Common.fields(request)}
    |> Map.merge(sound(push.level))
    |> Map.merge(thread(push))
  end

  defp sound(nil), do: %{}
  defp sound(:passive), do: %{}

  defp sound(:critical),
    do: %{"sound" => %{"critical" => 1, "name" => "default", "volume" => 1.0}}

  defp sound(_level), do: %{"sound" => "default"}

  defp thread(%{collapse: %{topic: topic}}), do: %{"thread-id" => topic}
  defp thread(_push), do: %{}

  # E-83
  defp data(request, push) do
    topic = if push.collapse, do: %{"topic" => push.collapse.topic}, else: %{}
    relay = topic |> Map.put("id", Common.content_id(request)) |> link(request, push)
    %{"relay" => relay}
  end

  defp link(relay, request, %{content_free: false}) do
    case Common.link(request) do
      nil -> relay
      url -> Map.put(relay, "url", url)
    end
  end

  defp link(relay, _request, _push), do: relay

  defp content_free(request, %{content_free: true} = push, :alert) do
    %{
      id: Common.content_id(request),
      locale: push.locale,
      lock_screen_body: push.lock_screen_body
    }
  end

  defp content_free(_request, _push, _type), do: nil

  defp call(request, settings, origin, built, notification) do
    scope = request.scope
    key = {scope.environment, "apns", origin, settings["team_id"], settings["key_id"]}
    auth = {Relay.Channels.Apns.Bearer, bearer(settings)}
    headers = [{"content-type", "application/json"} | built.headers]
    h2 = %{method: "POST", path: built.path, headers: headers, body: built.body}
    opts = Common.config(__MODULE__, :connection, [])

    case H2.request(scope.tenant_id, key, origin, auth, h2, request.timeout_ms, opts) do
      {:ok, response} -> answer(response, notification, built)
      {:not_sent, reason} -> {:not_sent, reason}
      {:uncertain, reason} -> {:uncertain, reason}
    end
  end

  defp bearer(settings) do
    %{
      team_id: settings["team_id"],
      key_id: settings["key_id"],
      label: settings["key_label"],
      refresh_after: settings["token_refresh_s"]
    }
  end

  # CH-32
  defp answer(response, notification, built) do
    case Failures.read(:apns, response, Relay.Clock.utc_now()) do
      :accepted ->
        id =
          case List.keyfind(response.headers, "apns-id", 0) do
            {_name, value} -> value
            nil -> Relay.Id.to_string(notification.apns_id)
          end

        detail = %{override_ignored: built.override_ignored}
        {:accepted, %{provider_message_id: id, detail: detail}}

      {:rejected, raw} ->
        {:rejected, raw}
    end
  end
end
