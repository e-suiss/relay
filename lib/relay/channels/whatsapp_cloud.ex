defmodule Relay.Channels.WhatsappCloud do
  @moduledoc """
  The WhatsApp Cloud API adapter (CH-1, CH-3, CH-57, CH-60): a thin Graph API client over `Relay.Channels.http_request/1`, with no SDK. One call is `POST /<version>/<phone_number_id>/messages` with the system user token of the provider account as a bearer token; the body comes from `Relay.Channels.Whatsapp.Message` (a template message, or free-form text when the channel step chose it for an open window).

  The send endpoint has no idempotency key, so the declared policy is `no_auto_retry` with `biz_opaque_callback_data` as the correlation field: an attempt whose answer never came is not sent again, and its final state comes from the status webhooks, which carry the correlation back (CH-60, T-28). The adapter decides nothing: it reports Meta's error code (`error.code`), or `http_<status>` when the body carries none, and the core classifies it through `errors.json` (CH-7, CH-59).

  The account's `settings` give the business number (`phone_number_id`) and, optionally, the Graph API version (`graph_api_version`, default `v24.0`).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Request
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
      request
      |> options(number, token, body)
      |> Relay.Channels.http_request()
      |> result()
    end
  end

  defp token(%Relay.Redacted{} = credentials) do
    case Relay.Redacted.expose(credentials) do
      value when is_binary(value) and value != "" -> {:ok, value}
      %{"access_token" => value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> rejected("credentials_missing")
    end
  end

  defp token(_credentials), do: rejected("credentials_missing")

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

  defp options(request, number, token, body) do
    version = version(request.account)

    extra =
      :relay
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:req_options, [])

    Keyword.merge(
      [
        method: :post,
        url: Enum.join([@base_url, version, number, "messages"], "/"),
        headers: [{"authorization", "Bearer " <> token}],
        json: body,
        receive_timeout: request.timeout_ms,
        connect_options: [timeout: request.timeout_ms]
      ],
      extra
    )
  end

  defp version(%{"settings" => %{"graph_api_version" => version}}) when is_binary(version) do
    if Regex.match?(@version_pattern, version), do: version, else: @version
  end

  defp version(_account), do: @version

  defp result({:ok, %Req.Response{status: 200, body: %{"messages" => [first | _]}}})
       when is_map(first) and is_binary(:erlang.map_get("id", first)) do
    detail =
      case first do
        %{"message_status" => status} when is_binary(status) -> %{"message_status" => status}
        _other -> %{}
      end

    {:accepted, %{provider_message_id: first["id"], delivery_rank: :accepted, detail: detail}}
  end

  defp result({:ok, %Req.Response{} = response}) do
    raw = %{"status" => response.status, "headers" => headers(response), "body" => response.body}
    {:rejected, decode(raw)}
  end

  defp result({:error, %Req.TransportError{reason: reason}})
       when reason in [:econnrefused, :nxdomain, :ehostunreach, :enetunreach],
       do: {:not_sent, Atom.to_string(reason)}

  defp result({:error, %Req.TransportError{reason: reason}}),
    do: {:uncertain, reason |> inspect() |> String.slice(0, 64)}

  defp result({:error, exception}),
    do: {:uncertain, exception.__struct__ |> inspect() |> String.slice(0, 64)}

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

  defp details(%{"details" => value}), do: text(value)
  defp details(_data), do: nil

  defp detail(_body), do: %{}

  defp text(value) when is_binary(value), do: String.slice(value, 0, 256)
  defp text(_value), do: nil
end
