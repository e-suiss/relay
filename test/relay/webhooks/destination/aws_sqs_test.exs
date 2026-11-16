defmodule Relay.Webhooks.Destination.AwsSqsTest do
  use ExUnit.Case, async: true

  import RelayTest.DestinationFixture

  alias Relay.Redacted
  alias Relay.Webhooks.Destination.AwsSqs
  alias Relay.Webhooks.Outcome

  @host "sqs.eu-central-1.amazonaws.com"
  @queue "https://sqs.eu-central-1.amazonaws.com/123456789012/orders"
  @sts "sts.eu-central-1.amazonaws.com"
  @role "arn:aws:iam::123456789012:role/relay-delivery"

  defp config(extra \\ %{}) do
    base = %{
      queue_url: @queue,
      region: "eu-central-1",
      access_key_id: "AKIDEXAMPLE0000000",
      credential: Redacted.wrap("sqs-secret-value")
    }

    Map.merge(base, extra)
  end

  defp sent_body do
    assert_received {:sent, connection, request}
    {connection, request, Jason.decode!(request.body)}
  end

  defp session_answer(expiration) do
    response(200, """
    <AssumeRoleResponse><AssumeRoleResult><Credentials>
    <AccessKeyId>ASIDEXAMPLE0000000</AccessKeyId>
    <SecretAccessKey>temporary-secret-value</SecretAccessKey>
    <SessionToken>temporary-session-token</SessionToken>
    <Expiration>#{expiration}</Expiration>
    </Credentials></AssumeRoleResult></AssumeRoleResponse>
    """)
  end

  describe "WH-18 success" do
    test "WH-18: the 2xx answer of SendMessage is the acknowledged write" do
      assert {:ok, receipt} = AwsSqs.deliver(config(), prepared(), options())
      assert %{kind: :write, status: 200, address: "203.0.114.10"} = receipt
      assert %Outcome{result: :delivered} = Outcome.classify({:ok, receipt}, now())

      {connection, request, body} = sent_body()
      assert %{host: @host, port: 443, address: {203, 0, 114, 10}} = connection
      assert %{method: "POST", path: "/"} = request
      assert header(request, "x-amz-target") == "AmazonSQS.SendMessage"
      assert header(request, "content-type") == "application/x-amz-json-1.0"
      assert header(request, "x-amz-date") == "20261116T080000Z"
      assert body["QueueUrl"] == @queue
      refute_received {:sent, _connection, _request}
    end

    test "WH-17: the call is signed for SQS with the endpoint's access key" do
      assert {:ok, _receipt} = AwsSqs.deliver(config(), prepared(), options())

      {_connection, request, _body} = sent_body()
      authorization = header(request, "authorization")
      scope = "Credential=AKIDEXAMPLE0000000/20261116/eu-central-1/sqs/aws4_request"

      assert authorization =~ scope
      assert authorization =~ "SignedHeaders=content-type;host;x-amz-date;x-amz-target,"
      assert header(request, "x-amz-security-token") == nil
    end
  end

  describe "WH-8 CloudEvents mode" do
    test "WH-8: structured mode is the default and puts the whole event in the body" do
      message = prepared()
      assert {:ok, _receipt} = AwsSqs.deliver(config(), message, options())

      {_connection, _request, body} = sent_body()
      assert body["MessageBody"] == message.body
      assert Jason.decode!(body["MessageBody"])["id"] == "evt_1"

      content_type = "application/cloudevents+json; charset=utf-8"
      attribute = %{"DataType" => "String", "StringValue" => content_type}
      assert body["MessageAttributes"] == %{"content-type" => attribute}
    end

    test "WH-8: binary mode puts data in the body and the attributes beside it" do
      config = config(%{cloudevents_mode: "binary"})
      assert {:ok, _receipt} = AwsSqs.deliver(config, prepared(), options())

      {_connection, _request, body} = sent_body()
      attributes = Map.new(body["MessageAttributes"], &{elem(&1, 0), elem(&1, 1)["StringValue"]})

      assert body["MessageBody"] == ~s({"order_id":"o-1"})
      assert attributes["ce_id"] == "evt_1"
      assert attributes["ce_type"] == "order.shipped"
      assert attributes["ce_subject"] == "order/o-1"
      assert attributes["ce_seq"] == "7"
      assert attributes["content-type"] == "application/json"
      refute Map.has_key?(attributes, "ce_datacontenttype")
    end

    test "WH-8: a mode that does not exist is an invalid destination" do
      config = config(%{cloudevents_mode: "batched"})

      assert {:error, failure} = AwsSqs.deliver(config, prepared(), options())
      assert %{class: :invalid, reason: "cloudevents_mode_invalid"} = failure
      refute_received {:sent, _connection, _request}
    end
  end

  describe "WH-20 ordering and WH-18 deduplication" do
    test "WH-20: on a FIFO queue the subject is the message group and the id deduplicates" do
      config = config(%{queue_url: @queue <> ".fifo"})
      assert {:ok, _receipt} = AwsSqs.deliver(config, prepared(), options())

      {_connection, _request, body} = sent_body()
      assert body["MessageGroupId"] == "order/o-1"
      assert body["MessageDeduplicationId"] == "evt_1"
    end

    test "AG-24: the same subject is the same group, also when it cannot be a group id" do
      config = config(%{queue_url: @queue <> ".fifo"})
      subject = "sipariş 1"
      digest = Base.encode16(:crypto.hash(:sha256, subject), case: :lower)

      assert {:ok, _receipt} = AwsSqs.deliver(config, prepared(%{subject: subject}), options())
      {_connection, _request, first} = sent_body()
      message = prepared(%{subject: subject, id: "evt_2"})
      assert {:ok, _receipt} = AwsSqs.deliver(config, message, options())
      {_connection, _request, second} = sent_body()

      assert first["MessageGroupId"] == digest
      assert second["MessageGroupId"] == digest
      assert second["MessageDeduplicationId"] == "evt_2"
    end

    test "WH-20: a standard queue gets neither a group nor a deduplication id" do
      assert {:ok, _receipt} = AwsSqs.deliver(config(), prepared(), options())

      {_connection, _request, body} = sent_body()
      refute Map.has_key?(body, "MessageGroupId")
      refute Map.has_key?(body, "MessageDeduplicationId")
    end
  end

  describe "WH-18 failures" do
    test "WH-18: the answers of the API are classified" do
      cases = [
        {400, :rejected, :dead_lettered},
        {403, :credentials, :retry},
        {429, :unavailable, :retry},
        {503, :unavailable, :retry}
      ]

      for {status, class, result} <- cases do
        answer(@host, response(status, ~s({"__type":"SomeError"})))

        assert {:error, failure} = AwsSqs.deliver(config(), prepared(), options())
        assert %{class: ^class, address: "203.0.114.10"} = failure
        assert failure.reason == "http_#{status}"
        assert %Outcome{result: ^result} = Outcome.classify({:error, failure}, now())
      end
    end

    test "WH-18: a connection error is retried" do
      answer(@host, {:error, %{class: :connect, reason: "econnrefused"}})

      assert {:error, failure} = AwsSqs.deliver(config(), prepared(), options())
      assert failure.class == :connect
      assert %Outcome{result: :retry} = Outcome.classify({:error, failure}, now())
    end
  end

  describe "WH-43 egress rules" do
    test "WH-43: a queue host that resolves to a blocked address is never called" do
      resolve(@host, {:ok, [{10, 0, 0, 1}]})

      assert {:error, failure} = AwsSqs.deliver(config(), prepared(), options())
      assert %{class: :blocked, address: "10.0.0.1"} = failure
      assert %Outcome{result: :dead_lettered} = Outcome.classify({:error, failure}, now())
      refute_received {:sent, _connection, _request}
    end

    test "WH-43: a queue URL that is not https or names a metadata host is refused" do
      plain = config(%{queue_url: "http://sqs.eu-central-1.amazonaws.com/1/q"})
      metadata = config(%{queue_url: "https://metadata.google.internal/1/q"})

      assert {:error, %{class: :invalid}} = AwsSqs.deliver(plain, prepared(), options())
      assert {:error, %{class: :blocked}} = AwsSqs.deliver(metadata, prepared(), options())
      refute_received {:sent, _connection, _request}
    end

    test "WH-43: a region that is not a region name never becomes a host" do
      config = config(%{region: "x.evil.example/"})

      assert {:error, %{class: :invalid, reason: "region_invalid"}} =
               AwsSqs.deliver(config, prepared(), options())

      refute_received {:sent, _connection, _request}
    end
  end

  describe "WH-17 IAM role" do
    test "WH-17: a role is assumed with the installation identity and the external id" do
      answer(@sts, session_answer("2026-11-16T09:00:00Z"))
      identity = %{access_key_id: "AKIDINSTALL0000000", secret_access_key: Redacted.wrap("base")}
      config = %{queue_url: @queue, region: "eu-central-1", role_arn: @role}
      options = options(token_cache: &cache/1, aws_identity: identity, aws_external_id: "tnt-1")

      assert {:ok, %{kind: :write}} = AwsSqs.deliver(config, prepared(), options)

      assert_received {:sent, %{host: @sts}, assume}
      parameters = URI.decode_query(assume.body)
      assert parameters["Action"] == "AssumeRole"
      assert parameters["RoleArn"] == @role
      assert parameters["ExternalId"] == "tnt-1"
      assert header(assume, "authorization") =~ "Credential=AKIDINSTALL0000000/20261116/"
      assert header(assume, "authorization") =~ "/eu-central-1/sts/aws4_request"
      assert_received {:cached, 3_600}

      assert_received {:sent, %{host: @host}, request}
      assert header(request, "authorization") =~ "Credential=ASIDEXAMPLE0000000/20261116/"
      assert header(request, "x-amz-security-token") == "temporary-session-token"

      assert {:ok, _receipt} = AwsSqs.deliver(config, prepared(), options)
      assert_received {:sent, %{host: @host}, _request}
      refute_received {:sent, %{host: @sts}, _request}
    end

    test "WH-17: a role with an access key is assumed with that key, without an external id" do
      answer(@sts, session_answer("2026-11-16T08:15:00Z"))
      options = options(token_cache: &cache/1, aws_session_s: 900)

      assert {:ok, _receipt} = AwsSqs.deliver(config(%{role_arn: @role}), prepared(), options)

      assert_received {:sent, %{host: @sts}, assume}
      parameters = URI.decode_query(assume.body)
      assert parameters["DurationSeconds"] == "900"
      refute Map.has_key?(parameters, "ExternalId")
      assert header(assume, "authorization") =~ "Credential=AKIDEXAMPLE0000000/"
      assert_received {:cached, 900}
    end

    test "WH-17: without the installation identity or the external id the role is not assumed" do
      config = %{queue_url: @queue, region: "eu-central-1", role_arn: @role}
      identity = %{access_key_id: "AKIDINSTALL0000000", secret_access_key: Redacted.wrap("base")}

      assert {:error, %{class: :credentials, reason: "installation_identity_missing"}} =
               AwsSqs.deliver(config, prepared(), options(token_cache: &cache/1))

      options = options(token_cache: &cache/1, aws_identity: identity)

      assert {:error, %{class: :credentials, reason: "external_id_missing"} = failure} =
               AwsSqs.deliver(config, prepared(), options)

      assert %Outcome{result: :retry} = Outcome.classify({:error, failure}, now())
      refute_received {:sent, _connection, _request}
    end

    test "WH-17: a refused role assumption means the credentials are not available" do
      answer(@sts, response(403, "<ErrorResponse/>"))
      options = options(token_cache: &cache/1)

      assert {:error, failure} = AwsSqs.deliver(config(%{role_arn: @role}), prepared(), options)
      assert %{class: :credentials, reason: "sts_http_403"} = failure
      refute_received {:cached, _lifetime}
    end

    test "WH-43: the role assumption goes through the egress rules as well" do
      resolve(@sts, {:ok, [{169, 254, 169, 254}]})
      options = options(token_cache: &cache/1)

      assert {:error, failure} = AwsSqs.deliver(config(%{role_arn: @role}), prepared(), options)
      assert %{class: :blocked, address: "169.254.169.254"} = failure
      refute_received {:sent, _connection, _request}
    end

    test "WH-17: a configuration without credentials is invalid" do
      config = %{queue_url: @queue, region: "eu-central-1"}

      assert {:error, %{class: :invalid, reason: "credentials_missing"}} =
               AwsSqs.deliver(config, prepared(), options())
    end
  end

  describe "WH-19 credentials" do
    test "WH-19: neither the secret nor the temporary credentials appear in a failure" do
      answer(@sts, session_answer("2026-11-16T09:00:00Z"))
      answer(@host, response(403, "denied"))
      options = options(token_cache: &cache/1)

      assert {:error, failure} = AwsSqs.deliver(config(%{role_arn: @role}), prepared(), options)

      refute inspect(failure) =~ "sqs-secret-value"
      refute inspect(failure) =~ "temporary-secret-value"
      refute inspect(failure) =~ "temporary-session-token"
      refute inspect(Process.get(:cached_token)) =~ "temporary"
    end
  end
end
