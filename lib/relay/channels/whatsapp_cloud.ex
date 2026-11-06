defmodule Relay.Channels.WhatsappCloud do
  @moduledoc """
  The WhatsApp Cloud API adapter (CH-1, CH-3, CH-57, CH-60): a thin Graph API client over `Relay.Channels.ProviderHttp.call/2`, with no SDK. One call is `POST /<version>/<phone_number_id>/messages` with the system user token of the provider account as a bearer token; the body comes from `Relay.Channels.Whatsapp.Message` (a template message, or free-form text when the channel step chose it for an open window). A raw `overrides.whatsapp.raw` block is merged deeply into that body; it cannot change the recipient, the correlation, the message type or the template, and its ignored paths are reported as `override_ignored` (API-23, CH-21).

  The send endpoint has no idempotency key, so the declared policy is `no_auto_retry` with `biz_opaque_callback_data` as the correlation field: an attempt whose answer never came is not sent again, and its final state comes from the status webhooks, which carry the correlation back (CH-60, T-28). The adapter decides nothing: it reports Meta's error code (`error.code`), or `http_<status>` when the body carries none, and the core classifies it through `errors.json` (CH-7, CH-59).

  The account's `settings` give the business number (`phone_number_id`) and, optionally, the Graph API version (`graph_api_version`, default `v24.0`).

  The settings check reads the business number (`GET /<version>/<phone_number_id>`): a number whose status is not `CONNECTED`, such as one pending, flagged, restricted or disconnected, does not send (CH-52).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.ProviderHttp
  alias Relay.Channels.Push.Override
  alias Relay.Channels.Request
  alias Relay.Channels.SettingsCheck
  alias Relay.Channels.Whatsapp.Message

  @base_url "https://graph.facebook.com"
  @version "v24.0"
  @version_pattern ~r/\Av[0-9]{1,3}\.[0-9]{1,2}\z/
  @phone_number_id ~r/\A[0-9]{1,32}\z/

  @impl Relay.Channels.Adapter
  def provider, do: "whatsapp_cloud"

  @impl Relay.Channels.Adapter
  def channels, do: ["whatsapp"]

  # CH-57
  # CH-60
  # T-43
  @impl Relay.Channels.Adapter
  def deliver(%Request{} = request) do
    with {:ok, token} <- token(request.credentials),
         {:ok, number} <- phone_number_id(request.account),
         {:ok, content} <- content(request.content),
         {:ok, body} <- body(request, content) do
      {body, ignored} = Override.whatsapp(body, raw(request.overrides))

      request
      |> options(number, token, body)
      |> ProviderHttp.call(request.timeout_ms)
      |> result(ignored)
    end
  end

  # CH-52
  # CH-61
  @impl Relay.Channels.Adapter
  def check_settings(%{account: account, credentials: credentials, timeout_ms: timeout_ms}) do
    with {:ok, token} <- token(credentials),
         {:ok, number} <- phone_number_id(account) do
      [
        method: :get,
        url: Enum.join([@base_url, version(account), number], "/"),
        headers: [{"authorization", "Bearer " <> token}],
        params: [fields: "status,code_verification_status"]
      ]
      |> ProviderHttp.call(timeout_ms)
      |> SettingsCheck.read(&number_status/1)
    else
      {:rejected, %{code: "credentials_missing"}} -> SettingsCheck.credentials(nil)
      {:rejected, %{code: _sender}} -> SettingsCheck.mismatch("phone_number_id", "set", nil)
    end
  end

  defp number_status(%Req.Response{status: 200, body: %{"status" => "CONNECTED"}}), do: :ok

  defp number_status(%Req.Response{status: 200, body: %{"status" => status}})
       when is_binary(status),
       do: SettingsCheck.mismatch("phone_number_status", "CONNECTED", status)

  defp number_status(%Req.Response{status: 404}),
    do: SettingsCheck.mismatch("phone_number_id", "registered", nil)

  defp number_status(%Req.Response{}), do: {:error, "unexpected_response"}

  defp token(nil), do: rejected("credentials_missing")

  defp token(credentials) do
    case Relay.Redacted.expose(credentials) do
      value when is_binary(value) and value != "" -> {:ok, value}
      %{"access_token" => value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> rejected("credentials_missing")
    end
  end

  defp phone_number_id(%{"settings" => %{"phone_number_id" => id}}) when is_binary(id) do
    if Regex.match?(@phone_number_id, id), do: {:ok, id}, else: rejected("sender_missing")
  end

  defp phone_number_id(_account), do: rejected("sender_missing")

  defp content(content) when is_map(content), do: {:ok, content}

  defp content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> rejected("content_invalid")
    end
  end

  defp content(_content), do: rejected("content_invalid")

  defp body(request, content) do
    to = Relay.Redacted.expose(request.target.value)
    correlation = Message.correlation(request.delivery_id, request.attempt_no)

    case Message.body(content, to, correlation) do
      {:ok, body} -> {:ok, body}
      {:error, :invalid_content} -> rejected("content_invalid")
    end
  end

  # API-23
  defp raw(%{"raw" => %{} = raw}), do: raw
  defp raw(_overrides), do: nil

  defp options(request, number, token, body) do
    [
      method: :post,
      url: Enum.join([@base_url, version(request.account), number, "messages"], "/"),
      headers: [{"authorization", "Bearer " <> token}],
      json: body
    ]
  end

  defp version(%{"settings" => %{"graph_api_version" => version}}) when is_binary(version) do
    if Regex.match?(@version_pattern, version), do: version, else: @version
  end

  defp version(_account), do: @version

  defp result({:ok, %Req.Response{status: 200, body: %{"messages" => [first | _]}}}, ignored)
       when is_map(first) and is_binary(:erlang.map_get("id", first)) do
    detail =
      case first do
        %{"message_status" => status} when is_binary(status) -> %{"message_status" => status}
        _other -> %{}
      end

    detail = if ignored == [], do: detail, else: Map.put(detail, "override_ignored", ignored)
    {:accepted, %{provider_message_id: first["id"], delivery_rank: :accepted, detail: detail}}
  end

  defp result({:ok, %Req.Response{} = response}, _ignored) do
    raw = %{"status" => response.status, "headers" => headers(response), "body" => response.body}
    {:rejected, decode(raw)}
  end

  defp result({:not_sent, reason}, _ignored), do: {:not_sent, reason}
  defp result({:uncertain, reason}, _ignored), do: {:uncertain, reason}

  defp headers(%Req.Response{headers: headers}) do
    for {name, values} <- headers, value <- List.wrap(values), do: {name, value}
  end

  defp rejected(code), do: {:rejected, %{code: code, status: nil}}

  # CH-7
  # CH-59
  # DS-11
  @impl Relay.Channels.Adapter
  def decode(%{"status" => status} = response) when is_integer(status) do
    body = Map.get(response, "body")

    code =
      case body do
        %{"error" => %{"code" => code}} when is_integer(code) -> Integer.to_string(code)
        %{"error" => %{"code" => code}} when is_binary(code) and code != "" -> code
        _none -> "http_" <> Integer.to_string(status)
      end

    %{
      code: code,
      status: status,
      retry_after_ms: retry_after(Map.get(response, "headers", [])),
      detail: detail(body)
    }
  end

  defp retry_after(headers) when is_list(headers) do
    case Enum.find(headers, fn {name, _value} -> String.downcase(name) == "retry-after" end) do
      {_name, value} -> Relay.Channels.retry_after_ms(value, Relay.Clock.utc_now())
      nil -> nil
    end
  end

  defp retry_after(_headers), do: nil

  defp detail(%{"error" => %{} = error}) do
    error
    |> Map.take(["type", "error_subcode", "fbtrace_id"])
    |> Map.put("details", details(error["error_data"]))
  end

  defp detail(_body), do: %{}

  defp details(%{"details" => value}), do: text(value)
  defp details(_data), do: nil

  defp text(value) when is_binary(value), do: String.slice(value, 0, 256)
  defp text(_value), do: nil
end
