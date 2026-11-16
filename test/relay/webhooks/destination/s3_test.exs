defmodule Relay.Webhooks.Destination.S3Test do
  use ExUnit.Case, async: true

  import RelayTest.DestinationFixture

  alias Relay.Redacted
  alias Relay.Webhooks.Batch
  alias Relay.Webhooks.Destination.S3
  alias Relay.Webhooks.Envelope
  alias Relay.Webhooks.Outcome

  @host "relay-events.s3.eu-central-1.amazonaws.com"

  defp config(extra \\ %{}) do
    base = %{
      bucket: "relay-events",
      region: "eu-central-1",
      access_key_id: "AKIDEXAMPLE0000000",
      credential: Redacted.wrap("store-secret-value")
    }

    Map.merge(base, extra)
  end

  defp batch(id \\ "whb_01JCX5") do
    bodies = [prepared().body, prepared(%{id: "evt_2", seq: 8}).body]
    {:ok, message} = Batch.prepared(id, bodies, 1)
    {message, bodies}
  end

  describe "WH-21 one object per batch" do
    test "WH-21: a batch is written as one object of CloudEvents JSON lines" do
      {message, [first, second]} = batch()

      assert {:ok, receipt} = S3.deliver(config(%{prefix: "events"}), message, options())
      assert %{kind: :write, status: 200, address: "203.0.114.10"} = receipt
      assert %Outcome{result: :delivered} = Outcome.classify({:ok, receipt}, now())

      assert_received {:sent, %{host: @host, port: 443}, request}
      assert %{method: "PUT", path: "/events/whb_01JCX5.jsonl"} = request
      assert request.body == first <> "\n" <> second <> "\n"
      assert header(request, "content-type") == "application/x-ndjson"
      refute_received {:sent, _connection, _request}

      lines = String.split(request.body, "\n", trim: true)
      assert Enum.map(lines, &Jason.decode!(&1)["id"]) == ["evt_1", "evt_2"]
      assert Enum.all?(lines, &(Jason.decode!(&1)["specversion"] == "1.0"))
    end

    test "WH-21: writing the same batch again writes the same object" do
      {message, _bodies} = batch()

      assert {:ok, _receipt} = S3.deliver(config(), message, options())
      assert_received {:sent, _connection, first}
      {again, _bodies} = batch()
      assert {:ok, _receipt} = S3.deliver(config(), %{again | attempt: 2}, options())
      assert_received {:sent, _connection, second}

      assert first.path == "/whb_01JCX5.jsonl"
      assert second.path == first.path
      assert second.body == first.body
      digest = Base.encode16(:crypto.hash(:sha256, first.body), case: :lower)
      assert header(first, "x-amz-content-sha256") == digest
      assert header(second, "x-amz-content-sha256") == digest
    end

    test "WH-21: a single event is written as a batch of one line" do
      message = prepared()

      assert {:ok, _receipt} = S3.deliver(config(), message, options())
      assert_received {:sent, _connection, request}

      assert request.path == "/evt_1.jsonl"
      assert request.body == message.body <> "\n"
      assert message.content_type == Envelope.content_type()
      assert header(request, "content-type") == "application/x-ndjson"
    end

    test "WH-21: a batch identifier that is not a file name is written under its digest" do
      {message, _bodies} = batch("batch 2026/11/16 #1")
      digest = Base.encode16(:crypto.hash(:sha256, "batch 2026/11/16 #1"), case: :lower)

      assert {:ok, _receipt} = S3.deliver(config(%{prefix: "a/b/"}), message, options())
      assert_received {:sent, _connection, request}
      assert request.path == "/a/b/" <> digest <> ".jsonl"
    end
  end

  describe "WH-17 object store address and credentials" do
    test "WH-17: the write is signed for S3 with the payload digest" do
      {message, _bodies} = batch()

      assert {:ok, _receipt} = S3.deliver(config(), message, options())
      assert_received {:sent, _connection, request}

      authorization = header(request, "authorization")
      assert authorization =~ "Credential=AKIDEXAMPLE0000000/20261116/eu-central-1/s3/"
      assert authorization =~ "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date,"
    end

    test "WH-17: a bucket with a dot in its name is addressed in path style" do
      {message, _bodies} = batch()
      config = config(%{bucket: "relay.events"})

      assert {:ok, _receipt} = S3.deliver(config, message, options())
      assert_received {:sent, %{host: "s3.eu-central-1.amazonaws.com"}, request}
      assert request.path == "/relay.events/whb_01JCX5.jsonl"
    end

    test "WH-17: a custom endpoint is addressed in path style under its own path" do
      {message, _bodies} = batch()
      config = config(%{endpoint: "https://store.example.net/s3/", prefix: "it's(ok)"})

      assert {:ok, _receipt} = S3.deliver(config, message, options())
      assert_received {:sent, %{host: "store.example.net", port: 443}, request}
      assert request.path == "/s3/relay-events/it%27s%28ok%29/whb_01JCX5.jsonl"
    end

    test "WH-17: a bucket, a prefix or an endpoint of the wrong form is invalid" do
      {message, _bodies} = batch()

      configs = [
        config(%{bucket: "Relay_Events"}),
        config(%{prefix: "a b?c"}),
        config(%{endpoint: "https://store.example.net/?x=1"}),
        config(%{endpoint: "https://user@store.example.net"}),
        config(%{region: "eu central"})
      ]

      for config <- configs do
        assert {:error, %{class: :invalid}} = S3.deliver(config, message, options())
      end

      refute_received {:sent, _connection, _request}
    end
  end

  describe "WH-18 failures" do
    test "WH-18: the answers of the store are classified" do
      {message, _bodies} = batch()

      cases = [
        {301, :rejected, :dead_lettered},
        {404, :rejected, :dead_lettered},
        {403, :credentials, :retry},
        {503, :unavailable, :retry}
      ]

      for {status, class, result} <- cases do
        answer(@host, response(status, "<Error/>"))

        assert {:error, failure} = S3.deliver(config(), message, options())
        assert %{class: ^class, address: "203.0.114.10"} = failure
        assert %Outcome{result: ^result} = Outcome.classify({:error, failure}, now())
      end
    end
  end

  describe "WH-43 egress rules" do
    test "WH-43: a custom endpoint that resolves to a blocked address is never called" do
      {message, _bodies} = batch()
      resolve("minio.internal.example", {:ok, [{10, 1, 2, 3}]})
      config = config(%{endpoint: "https://minio.internal.example"})

      assert {:error, failure} = S3.deliver(config, message, options())
      assert %{class: :blocked, address: "10.1.2.3"} = failure
      assert %Outcome{result: :dead_lettered} = Outcome.classify({:error, failure}, now())
      refute_received {:sent, _connection, _request}
    end

    test "WH-43: a custom endpoint obeys the registration rules" do
      {message, _bodies} = batch()

      endpoints = [
        {"http://store.example.net", :invalid},
        {"https://store.example.net:9000", :invalid},
        {"https://169.254.169.254", :blocked},
        {"https://metadata.google.internal", :blocked}
      ]

      for {endpoint, class} <- endpoints do
        config = config(%{endpoint: endpoint})
        assert {:error, %{class: ^class}} = S3.deliver(config, message, options())
      end

      refute_received {:sent, _connection, _request}
    end

    test "WH-43: the regional S3 host is validated as well" do
      {message, _bodies} = batch()
      resolve(@host, {:ok, [{0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}]})

      assert {:error, %{class: :blocked}} = S3.deliver(config(), message, options())
      refute_received {:sent, _connection, _request}
    end
  end

  describe "WH-19 credentials" do
    test "WH-19: the secret access key appears in no failure" do
      {message, _bodies} = batch()
      answer(@host, response(403, "denied"))

      assert {:error, failure} = S3.deliver(config(), message, options())
      refute inspect(failure) =~ "store-secret-value"
    end
  end
end
