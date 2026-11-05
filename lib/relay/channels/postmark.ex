defmodule Relay.Channels.Postmark do
  @moduledoc """
  The Postmark adapter (CH-3, CH-34): a thin client of Postmark's HTTP API on `Req`, with no SDK. A message is the one `Relay.Channels.Email` prepares, sent as its fields to `POST /email` with the server token of the account's credential (`{"server_token"}`); Postmark signs it with the domain's DKIM key and uses its own return path. Tracking is always off, so a link reaches the recipient as written (CH-43, CH-76). The message stream is the account's `settings.postmark.message_streams` entry of the e-mail stream, or Postmark's `outbound` and `broadcast`.

  The delivery identifier travels as the metadata `relay_delivery_id`, so an uncertain call is resolved by searching the outbound messages for it (`query/1`, T-28), and every event names its delivery. Postmark's error codes are reported as `postmark:<ErrorCode>` and HTTP statuses without one as `http_<status>`.

  Events come from Postmark's webhooks (delivery, bounce, spam complaint), authenticated by the basic credentials of the webhook URL; Postmark signs nothing, so their authenticity is declared unverifiable (§12.1.2). `events/1` parses a webhook body into `Relay.Channels.Email.Event`s.
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Email.Esp
  alias Relay.Channels.Email.Event
  alias Relay.Channels.Email.StatusCode
  alias Relay.Channels.Request

  @base_url "https://api.postmarkapp.com"
  @streams %{"transactional" => "outbound", "marketing" => "broadcast"}
  @bounces %{
    "HardBounce" => :bounced,
    "BadEmailAddress" => :bounced,
    "SoftBounce" => :bounced,
    "Transient" => :deferred,
    "DnsError" => :bounced,
    "Blocked" => :bounced,
    "DMARCPolicy" => :bounced,
    "SpamNotification" => :bounced,
    "VirusNotification" => :bounced,
    "ManuallyDeactivated" => :rejected,
    "Unknown" => :bounced,
    "SpamComplaint" => :complained
  }

  @impl Relay.Channels.Adapter
  def provider, do: "postmark"

  @impl Relay.Channels.Adapter
  def channels, do: ["email"]

  # CH-3
  # CH-34
  @impl Relay.Channels.Adapter
  def deliver(%Request{} = request) do
    with {:ok, token} <- token(request),
         {:ok, prepared} <- Esp.prepare(request) do
      body = message(request, prepared)

      case Esp.call(request, post("/email", token, body)) do
        {:ok, %Req.Response{status: 200} = response} -> accepted(response)
        {:ok, response} -> rejected(response)
        other -> other
      end
    end
  end

  # T-28
  @impl Relay.Channels.Adapter
  def query(%Request{} = request) do
    params = [
      count: 1,
      offset: 0,
      metadata_relay_delivery_id: Relay.Id.to_string(request.delivery_id)
    ]

    with {:ok, token} <- token(request),
         {:ok, %Req.Response{status: 200} = response} <-
           Esp.call(request, get("/messages/outbound", token, params)) do
      case Esp.json(response) do
        %{"Messages" => [%{"MessageID" => id} | _rest]} ->
          {:accepted, %{provider_message_id: id, delivery_rank: :accepted}}

        %{"TotalCount" => 0} ->
          :not_received

        _other ->
          :unavailable
      end
    else
      _unavailable -> :unavailable
    end
  end

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(%{"status" => status, "body" => body}) when is_integer(status),
    do: code(status, body)

  def decode(%{"failure" => failure}) when is_binary(failure), do: %{code: failure, status: nil}

  def decode(%{"event" => event}) do
    [%Event{code: code} | _rest] = events(event)
    %{code: "event:" <> code, status: nil}
  end

  defp token(request) do
    with {:ok, credentials} <- Esp.credentials(request),
         {:ok, token} <- Esp.secret(credentials, "server_token") do
      {:ok, token}
    else
      :error -> Esp.refused("credential_invalid")
    end
  end

  defp message(request, prepared) do
    streams = Map.get(Esp.settings(request, "postmark"), "message_streams", %{})
    stream = Map.get(streams, prepared.stream, Map.fetch!(@streams, prepared.stream))

    %{
      "From" => from(prepared),
      "To" => prepared.to,
      "Subject" => prepared.subject,
      "TextBody" => prepared.text,
      "HtmlBody" => prepared.html,
      "ReplyTo" => prepared.reply_to,
      "Headers" =>
        [{"Message-ID", prepared.message_id} | prepared.headers]
        |> Enum.map(fn {name, value} -> %{"Name" => name, "Value" => value} end),
      "TrackOpens" => false,
      "TrackLinks" => "None",
      "Metadata" => %{Event.correlation_key() => Relay.Id.to_string(request.delivery_id)},
      "MessageStream" => stream
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp from(%{from_name: nil, from: from}), do: from
  defp from(%{from_name: name, from: from}), do: ~s("#{String.replace(name, "\"", "")}" <#{from}>)

  defp post(path, token, body) do
    [
      method: :post,
      url: @base_url <> path,
      headers: headers(token),
      body: Jason.encode!(body)
    ]
  end

  defp get(path, token, params) do
    [method: :get, url: @base_url <> path, headers: headers(token), params: params]
  end

  defp headers(token) do
    [
      {"x-postmark-server-token", token},
      {"accept", "application/json"},
      {"content-type", "application/json"}
    ]
  end

  defp accepted(response) do
    case Esp.json(response) do
      %{"ErrorCode" => 0, "MessageID" => id} ->
        {:accepted, %{provider_message_id: id, delivery_rank: :accepted}}

      body ->
        Esp.rejected(response, code(200, body).code)
    end
  end

  defp rejected(response),
    do: Esp.rejected(response, code(response.status, Esp.json(response)).code)

  defp code(status, %{"ErrorCode" => error}) when is_integer(error) and error != 0,
    do: %{code: "postmark:" <> Integer.to_string(error), status: status}

  defp code(status, _body), do: %{code: Esp.http_code(status), status: status}

  # CH-39
  # CH-47
  @doc "Parses a Postmark webhook body (one record, decoded or as JSON text) into its events; a record of another type is `:ignored`."
  @spec events(binary() | map()) :: [Event.t()]
  def events(body) when is_binary(body), do: body |> Esp.json() |> events()

  def events(%{"RecordType" => "Delivery"} = record) do
    [event(record, :delivered, "Delivery", record["Recipient"], record["DeliveredAt"])]
  end

  def events(%{"RecordType" => "Bounce", "Type" => type} = record) when is_binary(type) do
    kind = Map.get(@bounces, type, :ignored)

    [
      %{
        event(record, kind, type, record["Email"], record["BouncedAt"])
        | status: status(record["Details"]),
          diagnostic: Event.redact(record["Details"])
      }
    ]
  end

  def events(%{"RecordType" => "SpamComplaint"} = record) do
    [event(record, :complained, "SpamComplaint", record["Email"], record["BouncedAt"])]
  end

  def events(%{"RecordType" => type} = record) when is_binary(type) do
    [event(record, :ignored, type, nil, nil)]
  end

  def events(_body), do: [%Event{provider: "postmark", type: :ignored, code: "Unknown"}]

  defp event(record, type, code, recipient, at) do
    metadata = if is_map(record["Metadata"]), do: record["Metadata"], else: %{}

    %Event{
      provider: "postmark",
      type: type,
      code: code,
      id: id(record["ID"]),
      delivery_id: Event.first_delivery_id([metadata[Event.correlation_key()]]),
      provider_message_id: record["MessageID"],
      recipient: Event.redact(recipient),
      occurred_at: Event.timestamp(at)
    }
  end

  defp id(id) when is_integer(id), do: Integer.to_string(id)
  defp id(id) when is_binary(id), do: id
  defp id(_id), do: nil

  defp status(details) when is_binary(details) do
    case StatusCode.find(details) do
      {:ok, status} -> StatusCode.to_string(status)
      :error -> nil
    end
  end

  defp status(_details), do: nil
end
