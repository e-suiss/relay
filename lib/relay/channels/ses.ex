defmodule Relay.Channels.Ses do
  @moduledoc """
  The Amazon SES adapter (CH-3, CH-34): a thin client of the SES v2 API on `Req`, with no SDK; requests are signed with AWS Signature Version 4 by `Req`'s own step, with the access key of the account's credential (`{"access_key_id", "secret_access_key"}` and an optional `"session_token"`). A message is the one `Relay.Channels.Email` prepares, sent as raw MIME to `POST /v2/email/outbound-emails`; SES signs it with the domain's Easy DKIM key and uses the configured MAIL FROM domain. SES adds no tracking unless the configuration set asks for it, and Relay asks for none (CH-43, CH-76).

  The account's `settings.ses` carry `"region"`, an optional `"configuration_set"` and, for events, `"queue_url"` and `"topic_arn"`. The delivery identifier travels as the message tag `relay_delivery_id`, which every event carries. SES has no idempotency key and no status query a send can be resolved by, so an uncertain call is not retried (CH-10). SES errors are reported as `ses:<error type>`, other HTTP statuses as `http_<status>`.

  Events reach Relay through a durable queue, never through a short-lived HTTP subscription (CH-47): SES publishes them to an SNS topic, the topic delivers them to the tenant's SQS queue, and Relay reads the queue (`receive_messages/3`), checks the SNS signature of each message (`Relay.Channels.Email.Sns`), parses the SES event (`events/2`) and deletes the message only once it is processed (`delete_message/3`).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Email
  alias Relay.Channels.Email.Esp
  alias Relay.Channels.Email.Event
  alias Relay.Channels.Email.Sns
  alias Relay.Channels.Request

  @region ~r/\A[a-z]{2}(-[a-z]+)+-\d{1,2}\z/
  @queue ~r/\Ahttps:\/\/sqs\.([a-z0-9\-]+)\.amazonaws\.com\/\d{12}\/[A-Za-z0-9_\-]{1,80}(\.fifo)?\z/
  @receive_ms 25_000

  @impl Relay.Channels.Adapter
  def provider, do: "ses"

  @impl Relay.Channels.Adapter
  def channels, do: ["email"]

  # CH-3
  # CH-34
  @impl Relay.Channels.Adapter
  def deliver(%Request{} = request) do
    settings = Esp.settings(request, "ses")

    with {:ok, region} <- region(settings),
         {:ok, credentials} <- credentials(Esp.credentials(request)),
         {:ok, prepared} <- Esp.prepare(request),
         {:ok, mime} <- mime(prepared) do
      body =
        %{
          "FromEmailAddress" => prepared.from,
          "Destination" => %{"ToAddresses" => [prepared.to]},
          "Content" => %{"Raw" => %{"Data" => Base.encode64(mime)}},
          "EmailTags" => [%{"Name" => Event.correlation_key(), "Value" => tag(request)}]
        }
        |> put("ConfigurationSetName", settings["configuration_set"])

      opts = [
        method: :post,
        url: "https://email." <> region <> ".amazonaws.com/v2/email/outbound-emails",
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(body),
        aws_sigv4: sigv4(credentials, :ses, region)
      ]

      case Esp.call(request, opts) do
        {:ok, %Req.Response{status: 200} = response} -> accepted(response)
        {:ok, %Req.Response{} = response} -> Esp.rejected(response, code(response))
        other -> other
      end
    end
  end

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(%{"status" => status} = response) when is_integer(status) do
    headers = Map.get(response, "headers", %{})
    body = Map.get(response, "body", %{})
    %{code: code(status, headers["x-amzn-errortype"], body), status: status}
  end

  def decode(%{"failure" => failure}) when is_binary(failure), do: %{code: failure, status: nil}

  def decode(%{"event" => event}) do
    [%Event{code: code} | _rest] = events(event, nil)
    %{code: "event:" <> code, status: nil}
  end

  defp tag(request), do: Relay.Id.to_string(request.delivery_id)

  defp region(%{"region" => region}) when is_binary(region) do
    if region =~ @region, do: {:ok, region}, else: Esp.refused("configuration_invalid")
  end

  defp region(_settings), do: Esp.refused("configuration_invalid")

  defp credentials({:ok, map}) do
    with {:ok, id} <- Esp.secret(map, "access_key_id"),
         {:ok, secret} <- Esp.secret(map, "secret_access_key") do
      {:ok, %{id: id, secret: secret, token: map["session_token"]}}
    else
      :error -> Esp.refused("credential_invalid")
    end
  end

  defp credentials(:error), do: Esp.refused("credential_invalid")

  defp mime(prepared) do
    case Email.mime(prepared) do
      {:ok, mime} -> {:ok, mime}
      {:error, _error} -> Esp.refused("message_invalid")
    end
  end

  defp sigv4(credentials, service, region) do
    [
      access_key_id: credentials.id,
      secret_access_key: credentials.secret,
      service: service,
      region: region,
      datetime: Relay.Clock.utc_now()
    ]
    |> then(&if(credentials.token, do: Keyword.put(&1, :token, credentials.token), else: &1))
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp accepted(response) do
    case Esp.json(response) do
      %{"MessageId" => id} when is_binary(id) ->
        {:accepted, %{provider_message_id: id, delivery_rank: :accepted}}

      _other ->
        {:accepted, %{provider_message_id: nil, delivery_rank: :accepted}}
    end
  end

  defp code(%Req.Response{} = response) do
    type =
      case Req.Response.get_header(response, "x-amzn-errortype") do
        [value | _rest] -> value
        [] -> nil
      end

    code(response.status, type, Esp.json(response))
  end

  defp code(status, type, body) do
    name =
      [type, body["__type"], body["code"], body["Code"]]
      |> Enum.find(&(is_binary(&1) and &1 != ""))

    case name do
      nil -> Esp.http_code(status)
      name -> "ses:" <> (name |> String.split(":") |> hd() |> String.split("#") |> List.last())
    end
  end

  # CH-47
  @doc "Receives up to ten messages from the account's SQS queue, waiting at most 20 seconds; returns each message's `\"ReceiptHandle\"` and `\"Body\"`."
  @spec receive_messages(map(), Relay.Redacted.t(), keyword()) ::
          {:ok, [map()]} | {:error, :configuration_invalid | :unavailable}
  def receive_messages(settings, credentials, opts \\ []) do
    wait_s = Keyword.get(opts, :wait_s, 20)

    body = %{
      "QueueUrl" => settings["queue_url"],
      "MaxNumberOfMessages" => 10,
      "WaitTimeSeconds" => wait_s,
      "VisibilityTimeout" => Keyword.get(opts, :visibility_s, 120)
    }

    with {:ok, response} <- sqs(settings, credentials, "ReceiveMessage", body, wait_s) do
      case Esp.json(response) do
        %{"Messages" => messages} when is_list(messages) -> {:ok, messages}
        _empty -> {:ok, []}
      end
    end
  end

  # CH-47
  @doc "Deletes a processed message from the account's SQS queue by its receipt handle."
  @spec delete_message(map(), Relay.Redacted.t(), String.t()) ::
          :ok | {:error, :configuration_invalid | :unavailable}
  def delete_message(settings, credentials, receipt_handle) when is_binary(receipt_handle) do
    body = %{"QueueUrl" => settings["queue_url"], "ReceiptHandle" => receipt_handle}

    with {:ok, _response} <- sqs(settings, credentials, "DeleteMessage", body, 0), do: :ok
  end

  defp sqs(settings, credentials, action, body, wait_s) do
    with {:ok, region} <- queue_region(settings["queue_url"]),
         {:ok, credentials} <-
           credentials(Esp.credential_map(credentials)) do
      opts = [
        method: :post,
        url: "https://sqs." <> region <> ".amazonaws.com/",
        headers: [
          {"content-type", "application/x-amz-json-1.0"},
          {"x-amz-target", "AmazonSQS." <> action}
        ],
        body: Jason.encode!(body),
        aws_sigv4: sigv4(credentials, :sqs, region)
      ]

      case Esp.http(wait_s * 1000 + @receive_ms, opts) do
        {:ok, %Req.Response{status: 200} = response} -> {:ok, response}
        _failed -> {:error, :unavailable}
      end
    else
      _invalid -> {:error, :configuration_invalid}
    end
  end

  defp queue_region(url) when is_binary(url) do
    case Regex.run(@queue, url, capture: :all_but_first) do
      [region | _rest] -> {:ok, region}
      nil -> :error
    end
  end

  defp queue_region(_url), do: :error

  # CH-47
  # T-40
  @doc "Verifies the SNS envelope of an SQS message body for the account's topic and parses its SES event; `fetch` reads an SNS signing certificate (`fetch_certificate/1` in production)."
  @spec message_events(map(), binary(), Sns.fetch()) ::
          {:ok, [Event.t()]} | {:error, Sns.reason()}
  def message_events(settings, body, fetch) do
    with {:ok, notification} <- Sns.verify(body, settings["topic_arn"] || "", fetch),
         do: {:ok, events(notification["Message"], notification["MessageId"])}
  end

  # T-40
  @doc "Fetches an SNS signing certificate over verified TLS after checking its URL."
  @spec fetch_certificate(String.t()) :: {:ok, binary()} | :error
  def fetch_certificate(url) do
    with {:ok, url} <- Sns.certificate_url(url),
         {:ok, %Req.Response{status: 200, body: pem}} when is_binary(pem) <-
           Esp.http(10_000, method: :get, url: url) do
      {:ok, pem}
    else
      _failed -> :error
    end
  end

  # CH-39
  # CH-47
  @doc "Parses an SES event (an SNS message, decoded or as JSON text) into one event per recipient; `id` is the SNS message identifier. An event type Relay does not act on is `:ignored`."
  @spec events(binary() | map(), String.t() | nil) :: [Event.t()]
  def events(message, id) when is_binary(message), do: message |> Esp.json() |> events(id)

  def events(%{} = message, id) do
    type = message["eventType"] || message["notificationType"]
    mail = if is_map(message["mail"]), do: message["mail"], else: %{}
    base = base(mail, id)

    case type do
      "Bounce" -> bounces(base, message["bounce"] || %{})
      "Complaint" -> complaints(base, message["complaint"] || %{})
      "Delivery" -> deliveries(base, message["delivery"] || %{})
      "DeliveryDelay" -> delays(base, message["deliveryDelay"] || %{})
      "Reject" -> [%{base | type: :rejected, code: "Reject"}]
      engagement when engagement in ["Open", "Click", "Subscription"] ->
        [%{base | type: :engagement, code: engagement}]

      other when is_binary(other) ->
        [%{base | code: other}]

      _missing ->
        [base]
    end
  end

  defp base(mail, id) do
    tags = if is_map(mail["tags"]), do: mail["tags"], else: %{}
    headers = if is_map(mail["commonHeaders"]), do: mail["commonHeaders"], else: %{}

    %Event{
      provider: "ses",
      type: :ignored,
      code: "Unknown",
      id: id,
      delivery_id:
        Event.first_delivery_id([first(tags[Event.correlation_key()]), headers["messageId"]]),
      provider_message_id: mail["messageId"]
    }
  end

  defp bounces(base, bounce) do
    code = (bounce["bounceType"] || "Undetermined") <> "/" <> (bounce["bounceSubType"] || "")

    for %{} = recipient <- list(bounce["bouncedRecipients"]) do
      %{
        base
        | type: :bounced,
          code: code,
          recipient: Event.redact(recipient["emailAddress"]),
          occurred_at: Event.timestamp(bounce["timestamp"]),
          status: recipient["status"],
          diagnostic: Event.redact(recipient["diagnosticCode"])
      }
    end
  end

  defp complaints(base, complaint) do
    for %{} = recipient <- list(complaint["complainedRecipients"]) do
      %{
        base
        | type: :complained,
          code: "Complaint",
          recipient: Event.redact(recipient["emailAddress"]),
          occurred_at: Event.timestamp(complaint["timestamp"])
      }
    end
  end

  defp deliveries(base, delivery) do
    for address <- list(delivery["recipients"]), is_binary(address) do
      %{
        base
        | type: :delivered,
          code: "Delivery",
          recipient: Event.redact(address),
          occurred_at: Event.timestamp(delivery["timestamp"])
      }
    end
  end

  defp delays(base, delay) do
    for %{} = recipient <- list(delay["delayedRecipients"]) do
      %{
        base
        | type: :deferred,
          code: "DeliveryDelay",
          recipient: Event.redact(recipient["emailAddress"]),
          occurred_at: Event.timestamp(delay["timestamp"]),
          status: recipient["status"],
          diagnostic: Event.redact(recipient["diagnosticCode"])
      }
    end
  end

  defp first([value | _rest]) when is_binary(value), do: value
  defp first(value) when is_binary(value), do: value
  defp first(_value), do: nil

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
end
