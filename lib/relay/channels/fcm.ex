defmodule Relay.Channels.Fcm do
  @moduledoc """
  The FCM HTTP v1 adapter (CH-1, CH-24); the retired legacy and batch endpoints are never used. It sends one message to one registration token over Relay's own HTTP/2 client (`Relay.Channels.Push.H2`); a connection serves one tenant environment and one Firebase project (INV-40), and the OAuth access token is fetched by Workload Identity Federation or a service account assertion signed in the key store and kept per connection for its lifetime (`Relay.Channels.Fcm.Bearer`, TN-30).

  The message carries the push policy of the channel step only (`Relay.Channels.Push.Policy`): the FCM `priority`, `ttl` from the message's `expires_at`, the class collapse key with the subject key in the data (CH-23), the Android channel of the category at the interruption level (CH-30, CH-65 (3)) and the content-free data form (CH-33); a raw `fcm.android`, `fcm.apns` or `fcm.webpush` override cannot change a policy field (CH-21). Acceptance is never delivery (CH-32).

  The account settings: `project_id` and either `auth: "service_account"` with `client_email`, `private_key_id` and `key_label`, or `auth: "workload_identity"` with `audience`, `subject_token_type` and optionally `service_account`, the workload's subject token being the account credential.

  The settings check takes a new access token for the account and sends a `validate_only` message to a topic, which FCM validates under the project's credentials without delivering it (CH-14, CH-52): a token endpoint that refuses the account, `401` or `403` is a credential mismatch and `404` a `project_id` mismatch. The installation configuration `config :relay, Relay.Channels.Fcm, origin: origin, connection: opts, http: opts` replaces the FCM host, the connection options and the token endpoint client options.
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Push.Common
  alias Relay.Channels.Push.Failures
  alias Relay.Channels.Push.Fcm
  alias Relay.Channels.Push.Fcm.Auth
  alias Relay.Channels.Push.H2
  alias Relay.Channels.Push.Ttl
  alias Relay.Channels.Request
  alias Relay.Channels.SettingsCheck

  @origin {:https, "fcm.googleapis.com", 443}
  @check_topic "relay-settings-check"
  @signal_ttl_s 60
  @signal_collapse "relay_sync"

  @impl Relay.Channels.Adapter
  def provider, do: "fcm"

  @impl Relay.Channels.Adapter
  def channels, do: ["push"]

  # CH-24
  # TN-30
  # INV-40
  # IN-35
  # IN-38
  @impl Relay.Channels.Adapter
  def deliver(%Request{signal: %{} = signal} = request) do
    with {:ok, settings} <- Common.settings(request, ["project_id"]),
         {:ok, source} <- source(settings),
         {:ok, message, ignored} <- Fcm.message(signal_message(request, signal)) do
      call(request, settings, source, message, ignored)
    else
      {:error, reason} -> Common.rejection(reason)
    end
  end

  def deliver(%Request{push: %{} = push} = request) do
    with {:ok, settings} <- Common.settings(request, ["project_id"]),
         {:ok, source} <- source(settings),
         {:ok, ttl} <- ttl(push),
         {:ok, message, ignored} <- Fcm.message(message(request, push, ttl)) do
      call(request, settings, source, message, ignored)
    else
      {:error, :expired} -> {:not_sent, "expired"}
      {:error, reason} -> Common.rejection(reason)
    end
  end

  def deliver(%Request{}), do: Common.rejection(:not_configured)

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(response), do: %{code: Failures.code(:fcm, response)}

  # CH-14
  # CH-52
  # TN-30
  @impl Relay.Channels.Adapter
  def check_settings(%{account: account, credentials: credentials, timeout_ms: timeout_ms}) do
    settings = Map.get(account, "settings") || %{}

    with :ok <- SettingsCheck.required(settings, ["project_id"]),
         {:ok, source} <- check_source(settings),
         {:ok, token} <- check_token(source, credentials, timeout_ms) do
      validate(account, settings["project_id"], token, timeout_ms)
    end
  end

  defp check_source(settings) do
    case source(settings) do
      {:ok, source} -> {:ok, source}
      {:error, :not_configured} -> SettingsCheck.mismatch("auth", "configured", nil)
    end
  end

  defp check_token(source, credentials, timeout_ms) do
    now = DateTime.to_unix(Relay.Clock.utc_now())
    opts = [http: &token_http(&1, timeout_ms), subject_token: fn -> subject(credentials) end]

    case Auth.access_token(source, %{}, now, opts) do
      {:ok, token, _cache} -> {:ok, token}
      {:error, error} -> token_failure(error)
    end
  end

  defp subject(nil), do: {:error, :missing}
  defp subject(credentials), do: {:ok, Relay.Redacted.expose(credentials)}

  defp token_http(request, timeout_ms) do
    case Common.http(__MODULE__, request, timeout_ms) do
      {:ok, %{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp token_failure(%Relay.Error{code: :fcm_auth_failed, details: %{status: status}})
       when status == 429 or status >= 500,
       do: {:error, "token_http_" <> Integer.to_string(status)}

  defp token_failure(%Relay.Error{code: :fcm_auth_failed, details: %{status: status}}),
    do: SettingsCheck.credentials("token_http_" <> Integer.to_string(status))

  defp token_failure(%Relay.Error{code: :fcm_auth_failed}),
    do: SettingsCheck.credentials("token_refused")

  defp token_failure(%Relay.Error{code: :fcm_auth_unavailable}),
    do: {:error, "token_unavailable"}

  defp token_failure(%Relay.Error{} = error), do: SettingsCheck.key_store(error, "key_label")

  defp validate(account, project_id, token, timeout_ms) do
    origin = Common.config(__MODULE__, :origin, @origin)
    key = {account["environment"], "fcm", origin, project_id, :check}
    project = URI.encode(project_id, &URI.char_unreserved?/1)
    message = %{"validate_only" => true, "message" => %{"topic" => @check_topic}}

    h2 = %{
      method: "POST",
      path: "/v1/projects/" <> project <> "/messages:send",
      headers: [
        {"authorization", "Bearer " <> Relay.Redacted.expose(token)},
        {"content-type", "application/json; charset=utf-8"}
      ],
      body: Jason.encode!(message)
    }

    opts = Common.config(__MODULE__, :connection, [])

    case H2.request(account["tenant_id"], key, origin, nil, h2, timeout_ms, opts) do
      {:ok, response} -> validated(response, project_id)
      {_transport, reason} -> {:error, reason}
    end
  end

  defp validated(%{status: status, body: body}, project_id) do
    code = Failures.code(:fcm, %{"status" => status, "body" => body})

    cond do
      status in 200..299 -> :ok
      status in [401, 403] -> SettingsCheck.credentials(code)
      status == 404 -> SettingsCheck.mismatch("project_id", project_id, code)
      true -> {:error, code}
    end
  end

  defp source(%{"auth" => "workload_identity"} = s) do
    if is_binary(s["audience"]) and is_binary(s["subject_token_type"]) do
      {:ok,
       %{
         kind: :workload_identity,
         project_id: s["project_id"],
         audience: s["audience"],
         subject_token_type: s["subject_token_type"],
         service_account: s["service_account"]
       }}
    else
      {:error, :not_configured}
    end
  end

  defp source(s) do
    if Enum.all?(~w(client_email private_key_id key_label), &is_binary(s[&1])) do
      {:ok,
       %{
         kind: :service_account,
         project_id: s["project_id"],
         client_email: s["client_email"],
         private_key_id: s["private_key_id"],
         label: s["key_label"]
       }}
    else
      {:error, :not_configured}
    end
  end

  # IN-35
  # IN-38
  # IN-52
  defp signal_message(request, signal) do
    data =
      %{
        "relay_sync" => "1",
        "relay_counter_version" => text(Map.get(signal, :counter_version)),
        "relay_read" => read(signal)
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    %{
      token: Relay.Redacted.expose(request.target.value),
      fcm_priority: :normal,
      ttl: "#{Map.get(signal, :ttl_s) || @signal_ttl_s}s",
      collapse_key: @signal_collapse,
      data: data,
      data_only: true
    }
  end

  defp text(nil), do: nil
  defp text(n) when is_integer(n), do: Integer.to_string(n)

  defp read(%{kind: :read, notification_id: <<_::128>> = id}),
    do: Relay.ExternalId.encode("ntf", id)

  defp read(_signal), do: nil

  defp ttl(push) do
    case Ttl.fcm(push.expires_at, push.now) do
      {:ok, ttl} -> {:ok, ttl}
      :expired -> {:error, :expired}
    end
  end

  defp message(request, push, ttl) do
    fields = Common.fields(request)
    data_only = push.message_class == :system

    %{
      token: Relay.Redacted.expose(request.target.value),
      fcm_priority: push.mapping.fcm_priority,
      ttl: ttl,
      collapse_key: push.collapse && push.collapse.fcm,
      topic: push.collapse && push.collapse.topic,
      channel_id: channel(push),
      notification: if(data_only, do: nil, else: Map.take(fields, ["title", "body"])),
      data: link(%{"relay_id" => Common.content_id(request)}, Common.link(request)),
      data_only: data_only,
      content_free: content_free(request, push, data_only),
      override_android: Common.override(request, "fcm", "android"),
      override_apns: Common.override(request, "fcm", "apns"),
      override_webpush: Common.override(request, "fcm", "webpush")
    }
  end

  # E-83
  defp link(data, nil), do: data
  defp link(data, url), do: Map.put(data, "relay_url", url)

  # CH-30
  # CH-65 (3)
  defp channel(%{category: category, level: level}) when is_binary(category) and level != nil do
    case Fcm.android_channel(category, level) do
      {:ok, channel} -> channel
      {:error, _error} -> nil
    end
  end

  defp channel(_push), do: nil

  defp content_free(request, %{content_free: true} = push, false) do
    %{
      id: Common.content_id(request),
      locale: push.locale,
      lock_screen_body: push.lock_screen_body
    }
  end

  defp content_free(_request, _push, _data_only), do: nil

  defp call(request, settings, source, message, ignored) do
    scope = request.scope
    origin = Common.config(__MODULE__, :origin, @origin)
    key = {scope.environment, "fcm", origin, settings["project_id"]}
    subject = request.credentials
    auth = {Relay.Channels.Fcm.Bearer, %{source: source, subject_token: subject}}
    project = URI.encode(settings["project_id"], &URI.char_unreserved?/1)

    h2 = %{
      method: "POST",
      path: "/v1/projects/" <> project <> "/messages:send",
      headers: [{"content-type", "application/json; charset=utf-8"}],
      body: Jason.encode!(%{"message" => message})
    }

    opts = Common.config(__MODULE__, :connection, [])

    case H2.request(scope.tenant_id, key, origin, auth, h2, request.timeout_ms, opts) do
      {:ok, response} -> answer(response, ignored)
      {:not_sent, reason} -> {:not_sent, reason}
      {:uncertain, reason} -> {:uncertain, reason}
    end
  end

  # CH-32
  defp answer(response, ignored) do
    case Failures.read(:fcm, response, Relay.Clock.utc_now()) do
      :accepted ->
        id =
          case Jason.decode(response.body) do
            {:ok, %{"name" => name}} when is_binary(name) -> name
            _other -> nil
          end

        {:accepted, %{provider_message_id: id, detail: %{override_ignored: ignored}}}

      {:rejected, raw} ->
        {:rejected, raw}
    end
  end
end
