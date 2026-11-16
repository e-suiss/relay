defmodule Relay.Webhooks.Destination.AwsEventbridgeTest do
  use ExUnit.Case, async: true

  import RelayTest.DestinationFixture

  alias Relay.Redacted
  alias Relay.Webhooks.Destination.AwsEventbridge
  alias Relay.Webhooks.Outcome

  @host "events.eu-central-1.amazonaws.com"
  @bus "arn:aws:events:eu-central-1:123456789012:event-bus/orders"
  @accepted ~s({"FailedEntryCount":0,"Entries":[{"EventId":"11710aed"}]})

  defp config(extra \\ %{}) do
    base = %{
      event_bus_arn: @bus,
      region: "eu-central-1",
      access_key_id: "AKIDEXAMPLE0000000",
      credential: Redacted.wrap("bus-secret-value")
    }

    Map.merge(base, extra)
  end

  defp failed(code),
    do: Jason.encode!(%{"FailedEntryCount" => 1, "Entries" => [%{"ErrorCode" => code}]})

  describe "WH-18 success" do
    test "WH-18: a 200 answer without a failed entry is the acknowledged write" do
      answer(@host, response(200, @accepted))
      message = prepared()

      assert {:ok, receipt} = AwsEventbridge.deliver(config(), message, options())
      assert %{kind: :write, status: 200, address: "203.0.114.10"} = receipt
      assert %Outcome{result: :delivered} = Outcome.classify({:ok, receipt}, now())

      assert_received {:sent, %{host: @host, port: 443}, request}
      assert header(request, "x-amz-target") == "AWSEvents.PutEvents"
      assert header(request, "content-type") == "application/x-amz-json-1.1"
      assert header(request, "authorization") =~ "/eu-central-1/events/aws4_request"

      assert %{"Entries" => [entry]} = Jason.decode!(request.body)
      assert entry["EventBusName"] == @bus
      assert entry["Source"] == "https://shop.example/orders"
      assert entry["DetailType"] == "order.shipped"
      assert entry["Detail"] == message.body
    end

    test "WH-8: the detail is the whole event in structured mode, id included" do
      answer(@host, response(200, @accepted))

      assert {:ok, _receipt} = AwsEventbridge.deliver(config(), prepared(), options())
      assert_received {:sent, _connection, request}

      %{"Entries" => [%{"Detail" => detail}]} = Jason.decode!(request.body)
      assert %{"specversion" => "1.0", "id" => "evt_1", "seq" => 7} = Jason.decode!(detail)
    end
  end

  describe "WH-18 failures" do
    test "WH-18: a 200 answer with a failed entry is not a success" do
      cases = [
        {"ThrottlingException", :unavailable, :retry},
        {"InternalFailure", :unavailable, :retry},
        {"AccessDeniedException", :credentials, :retry},
        {"MalformedDetail", :rejected, :dead_lettered}
      ]

      for {code, class, result} <- cases do
        answer(@host, response(200, failed(code)))

        assert {:error, failure} = AwsEventbridge.deliver(config(), prepared(), options())
        assert %{class: ^class, address: "203.0.114.10"} = failure
        assert failure.reason == "eventbridge_" <> code
        assert %Outcome{result: ^result} = Outcome.classify({:error, failure}, now())
      end
    end

    test "WH-18: an error code that is not a plain code is not copied into the reason" do
      answer(@host, response(200, failed("bad code\r\nwith text")))

      assert {:error, failure} = AwsEventbridge.deliver(config(), prepared(), options())
      assert %{class: :rejected, reason: "eventbridge_entry_failed"} = failure
    end

    test "WH-18: an answer that cannot be read is retried" do
      answer(@host, response(200, "<html>"))

      assert {:error, failure} = AwsEventbridge.deliver(config(), prepared(), options())
      assert %{class: :protocol, reason: "response_unreadable"} = failure
      assert %Outcome{result: :retry} = Outcome.classify({:error, failure}, now())

      cut = {:ok, %{status: 200, headers: [], body: "{", truncated: true}}
      answer(@host, cut)

      assert {:error, %{class: :protocol}} =
               AwsEventbridge.deliver(config(), prepared(), options())
    end

    test "WH-18: the other answers of the API are classified by status" do
      cases = [{400, :rejected}, {403, :credentials}, {500, :unavailable}]

      for {status, class} <- cases do
        answer(@host, response(status, "{}"))

        assert {:error, failure} = AwsEventbridge.deliver(config(), prepared(), options())
        assert %{class: ^class} = failure
        assert failure.reason == "http_#{status}"
      end
    end

    test "WH-17: a bus that is not an ARN is an invalid destination" do
      config = config(%{event_bus_arn: "orders"})

      assert {:error, failure} = AwsEventbridge.deliver(config, prepared(), options())
      assert %{class: :invalid, reason: "event_bus_arn_invalid"} = failure
      refute_received {:sent, _connection, _request}
    end
  end

  describe "WH-43 egress rules" do
    test "WH-43: an API host that resolves to a blocked address is never called" do
      resolve(@host, {:ok, [{127, 0, 0, 1}]})

      assert {:error, failure} = AwsEventbridge.deliver(config(), prepared(), options())
      assert %{class: :blocked, address: "127.0.0.1"} = failure
      assert %Outcome{result: :dead_lettered} = Outcome.classify({:error, failure}, now())
      refute_received {:sent, _connection, _request}
    end
  end

  describe "WH-19 credentials" do
    test "WH-19: the secret access key appears in no failure" do
      answer(@host, response(403, "denied"))

      assert {:error, failure} = AwsEventbridge.deliver(config(), prepared(), options())
      refute inspect(failure) =~ "bus-secret-value"
    end
  end
end
