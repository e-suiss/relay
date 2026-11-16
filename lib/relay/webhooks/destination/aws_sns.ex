defmodule Relay.Webhooks.Destination.AwsSns do
  @moduledoc """
  The Amazon SNS destination (WH-17): one `Publish` call of the SNS query protocol, signed with Signature Version 4 and sent to the regional SNS host through the egress boundary (WH-43). Success is the 2xx answer of the API (WH-18).

  Configuration: `:topic_arn`, `:region`, the credentials of `Relay.Webhooks.Destination.Aws` and `:cloudevents_mode` (`"structured"` by default).

  There is no CloudEvents binding for SNS, so the modes follow the general rule (WH-8 (3)). In structured mode the message is the whole event and a `content-type` message attribute names its format. In binary mode the message is `data` and the context attributes are string message attributes with the `ce_` prefix.

  On a FIFO topic the ordering key of the event is the message group (WH-20 (3)) and the CloudEvents `id` is the deduplication identifier (WH-18). An event without an ordering key is its own group.
  """

  @behaviour Relay.Webhooks.Destination

  alias Relay.Webhooks.Destination.Aws
  alias Relay.Webhooks.Destination.Cloud
  alias Relay.Webhooks.Envelope

  @headers [{"content-type", "application/x-www-form-urlencoded; charset=utf-8"}]

  # WH-17
  # WH-18
  @impl Relay.Webhooks.Destination
  def deliver(config, prepared, opts) when is_map(config) and is_list(opts) do
    with {:ok, topic} <- topic(config),
         {:ok, region} <- Aws.region(config),
         {:ok, mode} <- Cloud.mode(config, :structured) do
      body = URI.encode_query(parameters(topic, mode, prepared))
      url = "https://" <> Aws.host("sns", region) <> "/"
      request = %{method: "POST", url: url, headers: @headers, body: body}
      config |> Aws.call("sns", request, opts) |> Cloud.settle()
    end
  end

  defp topic(config) do
    topic = Map.get(config, :topic_arn)
    if Aws.arn?(topic), do: {:ok, topic}, else: Cloud.invalid("topic_arn_invalid")
  end

  defp parameters(topic, mode, prepared) do
    fixed = [
      {"Action", "Publish"},
      {"Version", "2010-03-31"},
      {"TopicArn", topic},
      {"Message", message(mode, prepared)}
    ]

    indexed = Enum.with_index(attributes(mode, prepared), 1)
    fixed ++ Enum.flat_map(indexed, &attribute/1) ++ fifo(topic, prepared)
  end

  # WH-8 (3)
  defp message(:structured, prepared), do: prepared.body
  defp message(:binary, prepared), do: prepared.data

  defp attributes(:structured, prepared), do: [{"content-type", prepared.content_type}]

  defp attributes(:binary, prepared) do
    content_type = {"content-type", Cloud.data_content_type(prepared)}
    [content_type | Envelope.binary_headers(prepared.attributes, :kafka)]
  end

  defp attribute({{name, value}, index}) do
    entry = "MessageAttributes.entry." <> Integer.to_string(index)

    [
      {entry <> ".Name", name},
      {entry <> ".Value.DataType", "String"},
      {entry <> ".Value.StringValue", value}
    ]
  end

  # WH-20 (3)
  # WH-18
  defp fifo(topic, prepared) do
    if String.ends_with?(topic, ".fifo"),
      do: [{"MessageGroupId", Aws.group_id(prepared)}, {"MessageDeduplicationId", prepared.id}],
      else: []
  end
end
