defmodule Relay.Webhooks.Destination.AwsSqs do
  @moduledoc """
  The Amazon SQS destination (WH-17): one `SendMessage` call of the SQS JSON protocol, signed with Signature Version 4 and sent to the host of the queue URL through the egress boundary (WH-43). Success is the 2xx answer of the API, which SQS gives once the message is stored (WH-18).

  Configuration: `:queue_url`, `:region`, the credentials of `Relay.Webhooks.Destination.Aws` (`:access_key_id` with `:credential`, or `:role_arn`) and `:cloudevents_mode` (`"structured"` by default).

  There is no CloudEvents binding for SQS, so the modes follow the general rule (WH-8 (3)). In structured mode the message body is the whole event and a `content-type` message attribute names its format. In binary mode the body is `data`, and the context attributes are string message attributes with the `ce_` prefix; SQS takes at most ten message attributes, so an event with more context attributes than that is refused by the queue.

  On a FIFO queue the ordering key of the event is the message group, so the events of one subject keep their order (WH-20 (3)), and the CloudEvents `id` is the deduplication identifier (WH-18). An event without an ordering key is its own group.
  """

  @behaviour Relay.Webhooks.Destination

  alias Relay.Webhooks.Destination.Aws
  alias Relay.Webhooks.Destination.Cloud
  alias Relay.Webhooks.Envelope

  @headers [
    {"content-type", "application/x-amz-json-1.0"},
    {"x-amz-target", "AmazonSQS.SendMessage"}
  ]

  # WH-17
  # WH-18
  @impl Relay.Webhooks.Destination
  def deliver(%{queue_url: queue_url} = config, prepared, opts)
      when is_binary(queue_url) and is_list(opts) do
    with {:ok, mode} <- Cloud.mode(config, :structured),
         {:ok, endpoint} <- endpoint(queue_url) do
      body = Jason.encode!(message(queue_url, mode, prepared))
      request = %{method: "POST", url: endpoint, headers: @headers, body: body}
      config |> Aws.call("sqs", request, opts) |> Cloud.settle()
    end
  end

  def deliver(_config, _prepared, _opts), do: Cloud.invalid("queue_url_invalid")

  defp endpoint(queue_url) do
    case URI.new(queue_url) do
      {:ok, %URI{scheme: "https", host: host, port: port, userinfo: nil}}
      when is_binary(host) and host != "" ->
        {:ok, "https://" <> host <> port(port) <> "/"}

      _other ->
        Cloud.invalid("queue_url_invalid")
    end
  end

  defp port(443), do: ""
  defp port(port), do: ":" <> Integer.to_string(port)

  defp message(queue_url, mode, prepared) do
    attributes = Map.new(attributes(mode, prepared), &attribute/1)
    message = %{"QueueUrl" => queue_url, "MessageBody" => body(mode, prepared)}

    message
    |> Map.put("MessageAttributes", attributes)
    |> Map.merge(fifo(queue_url, prepared))
  end

  # WH-8 (3)
  defp body(:structured, prepared), do: prepared.body
  defp body(:binary, prepared), do: prepared.data

  defp attributes(:structured, prepared), do: [{"content-type", prepared.content_type}]

  defp attributes(:binary, prepared) do
    content_type = {"content-type", Cloud.data_content_type(prepared)}
    [content_type | Envelope.binary_headers(prepared.attributes, :kafka)]
  end

  defp attribute({name, value}), do: {name, %{"DataType" => "String", "StringValue" => value}}

  # WH-20 (3)
  # WH-18
  defp fifo(queue_url, prepared) do
    if String.ends_with?(queue_url, ".fifo"),
      do: %{"MessageGroupId" => Aws.group_id(prepared), "MessageDeduplicationId" => prepared.id},
      else: %{}
  end
end
