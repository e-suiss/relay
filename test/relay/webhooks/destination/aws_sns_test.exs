defmodule Relay.Webhooks.Destination.AwsSnsTest do
  use ExUnit.Case, async: true

  import RelayTest.DestinationFixture

  alias Relay.Redacted
  alias Relay.Webhooks.Destination.AwsSns
  alias Relay.Webhooks.Outcome

  @host "sns.eu-central-1.amazonaws.com"
  @topic "arn:aws:sns:eu-central-1:123456789012:orders"

  defp config(extra \\ %{}) do
    base = %{
      topic_arn: @topic,
      region: "eu-central-1",
      access_key_id: "AKIDEXAMPLE0000000",
      credential: Redacted.wrap("sns-secret-value")
    }

    Map.merge(base, extra)
  end

  defp sent_parameters do
    assert_received {:sent, connection, request}
    {connection, request, URI.decode_query(request.body)}
  end

  defp attributes(parameters) do
    for {"MessageAttributes.entry." <> rest, name} <- parameters,
        [index, "Name"] <- [String.split(rest, ".")],
        into: %{},
        do: {name, parameters["MessageAttributes.entry." <> index <> ".Value.StringValue"]}
  end

  describe "WH-18 success" do
    test "WH-18: the 2xx answer of Publish is the acknowledged write" do
      assert {:ok, receipt} = AwsSns.deliver(config(), prepared(), options())
      assert %{kind: :write, status: 200, address: "203.0.114.10"} = receipt
      assert %Outcome{result: :delivered} = Outcome.classify({:ok, receipt}, now())

      {connection, request, parameters} = sent_parameters()
      assert %{host: @host, port: 443} = connection
      assert %{method: "POST", path: "/"} = request
      assert parameters["Action"] == "Publish"
      assert parameters["Version"] == "2010-03-31"
      assert parameters["TopicArn"] == @topic
      assert header(request, "authorization") =~ "/eu-central-1/sns/aws4_request"
      assert header(request, "authorization") =~ "SignedHeaders=content-type;host;x-amz-date,"
    end

    test "WH-17: a topic in a China region is published to the host of that partition" do
      config = config(%{topic_arn: "arn:aws-cn:sns:cn-north-1:123456789012:orders"})
      config = Map.put(config, :region, "cn-north-1")

      assert {:ok, _receipt} = AwsSns.deliver(config, prepared(), options())
      assert_received {:sent, %{host: "sns.cn-north-1.amazonaws.com.cn"}, _request}
    end
  end

  describe "WH-8 CloudEvents mode" do
    test "WH-8: structured mode is the default and publishes the whole event" do
      message = prepared()
      assert {:ok, _receipt} = AwsSns.deliver(config(), message, options())

      {_connection, _request, parameters} = sent_parameters()
      content_type = "application/cloudevents+json; charset=utf-8"
      assert parameters["Message"] == message.body
      assert attributes(parameters) == %{"content-type" => content_type}
    end

    test "WH-8: binary mode publishes data with the attributes as message attributes" do
      config = config(%{cloudevents_mode: "binary"})
      assert {:ok, _receipt} = AwsSns.deliver(config, prepared(), options())

      {_connection, _request, parameters} = sent_parameters()
      attributes = attributes(parameters)

      assert parameters["Message"] == ~s({"order_id":"o-1"})
      assert parameters["MessageAttributes.entry.1.Value.DataType"] == "String"
      assert attributes["ce_id"] == "evt_1"
      assert attributes["ce_source"] == "https://shop.example/orders"
      assert attributes["ce_subject"] == "order/o-1"
      assert attributes["content-type"] == "application/json"
    end
  end

  describe "WH-20 ordering and WH-18 deduplication" do
    test "WH-20: on a FIFO topic the subject is the message group and the id deduplicates" do
      config = config(%{topic_arn: @topic <> ".fifo"})
      assert {:ok, _receipt} = AwsSns.deliver(config, prepared(), options())

      {_connection, _request, parameters} = sent_parameters()
      assert parameters["MessageGroupId"] == "order/o-1"
      assert parameters["MessageDeduplicationId"] == "evt_1"
    end

    test "AG-24: an event without a subject is its own group" do
      config = config(%{topic_arn: @topic <> ".fifo"})
      assert {:ok, _receipt} = AwsSns.deliver(config, prepared(%{subject: nil}), options())

      {_connection, _request, parameters} = sent_parameters()
      assert parameters["MessageGroupId"] == "evt_1"
    end

    test "WH-20: a standard topic gets neither a group nor a deduplication id" do
      assert {:ok, _receipt} = AwsSns.deliver(config(), prepared(), options())

      {_connection, _request, parameters} = sent_parameters()
      refute Map.has_key?(parameters, "MessageGroupId")
      refute Map.has_key?(parameters, "MessageDeduplicationId")
    end
  end

  describe "WH-18 failures" do
    test "WH-18: the answers of the API are classified" do
      cases = [
        {400, :rejected, :dead_lettered},
        {404, :rejected, :dead_lettered},
        {403, :credentials, :retry},
        {500, :unavailable, :retry}
      ]

      for {status, class, result} <- cases do
        answer(@host, response(status, "<ErrorResponse/>"))

        assert {:error, failure} = AwsSns.deliver(config(), prepared(), options())
        assert %{class: ^class, address: "203.0.114.10"} = failure
        assert %Outcome{result: ^result} = Outcome.classify({:error, failure}, now())
      end
    end

    test "WH-17: a topic that is not an ARN is an invalid destination" do
      config = config(%{topic_arn: "orders"})

      assert {:error, failure} = AwsSns.deliver(config, prepared(), options())
      assert %{class: :invalid, reason: "topic_arn_invalid"} = failure
      refute_received {:sent, _connection, _request}
    end
  end

  describe "WH-43 egress rules" do
    test "WH-43: an API host that resolves to a blocked address is never called" do
      resolve(@host, {:ok, [{192, 168, 1, 10}]})

      assert {:error, failure} = AwsSns.deliver(config(), prepared(), options())
      assert %{class: :blocked, address: "192.168.1.10"} = failure
      assert %Outcome{result: :dead_lettered} = Outcome.classify({:error, failure}, now())
      refute_received {:sent, _connection, _request}
    end
  end

  describe "WH-19 credentials" do
    test "WH-19: the secret access key appears in no failure" do
      answer(@host, response(403, "denied"))

      assert {:error, failure} = AwsSns.deliver(config(), prepared(), options())
      refute inspect(failure) =~ "sns-secret-value"
    end
  end
end
