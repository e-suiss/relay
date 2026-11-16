defmodule Relay.Webhooks.Destination.AzureServiceBusTest do
  use ExUnit.Case, async: true

  import RelayTest.DestinationFixture

  alias Relay.Redacted
  alias Relay.Webhooks.Destination.AzureServiceBus
  alias Relay.Webhooks.Outcome

  @host "shop.servicebus.windows.net"
  @client_id "6f1c5a2e-58a1-4d0f-9d4b-0f6f4c7f3b11"

  setup do
    answer(@host, response(201))
    access = Base.encode64(:crypto.hash(:sha256, "service bus test key"))

    fields = [
      "Endpoint=sb://other.servicebus.windows.net/",
      "SharedAccessKeyName=relay-send",
      Enum.join(["SharedAccessKey", access], "=")
    ]

    config = %{
      namespace: @host,
      entity: "orders",
      credential: Redacted.wrap(Enum.join(fields, ";"))
    }

    %{config: config, access: access, options: options(credential_ttl_s: 300)}
  end

  defp identity(client_id, resource) do
    send(self(), {:identity, client_id, resource})
    Process.get(:identity, {:ok, Redacted.wrap("bearer-1")})
  end

  defp properties(request), do: Jason.decode!(header(request, "brokerproperties"))

  describe "WH-18 success" do
    test "WH-18: the 2xx answer to the message is the acknowledged write", ctx do
      assert {:ok, receipt} = AzureServiceBus.deliver(ctx.config, prepared(), ctx.options)
      assert %{kind: :write, status: 201, address: "203.0.114.10"} = receipt
      assert %Outcome{result: :delivered} = Outcome.classify({:ok, receipt}, now())

      assert_received {:sent, %{host: @host, port: 443}, request}
      assert %{method: "POST", path: "/orders/messages"} = request
      refute_received {:sent, _connection, _request}
    end

    test "WH-17: a topic path is sent segment by segment", ctx do
      config = %{ctx.config | entity: "sales/orders~eu!"}

      assert {:ok, _receipt} = AzureServiceBus.deliver(config, prepared(), ctx.options)
      assert_received {:sent, _connection, %{path: "/sales/orders~eu%21/messages"}}
    end
  end

  describe "WH-17 connection credential" do
    test "WH-17: the request carries a shared access signature for the entity", ctx do
      assert {:ok, _receipt} = AzureServiceBus.deliver(ctx.config, prepared(), ctx.options)
      assert_received {:sent, _connection, request}

      "SharedAccessSignature " <> token = header(request, "authorization")
      fields = URI.decode_query(token)
      expiry = DateTime.to_unix(now()) + 300
      scope = URI.encode_www_form("https://shop.servicebus.windows.net/orders")
      to_sign = scope <> "\n" <> Integer.to_string(expiry)
      expected = Base.encode64(:crypto.mac(:hmac, :sha256, ctx.access, to_sign))

      assert fields["sr"] == "https://shop.servicebus.windows.net/orders"
      assert fields["se"] == Integer.to_string(expiry)
      assert fields["skn"] == "relay-send"
      assert fields["sig"] == expected
      assert token =~ "sr=" <> scope <> "&sig="
    end

    test "WH-17: a connection string that holds a signature is used as it is", ctx do
      signature = "SharedAccessSignature sr=x&sig=y&se=1&skn=z"
      credential = Redacted.wrap("Endpoint=sb://x/;SharedAccessSignature=" <> signature)
      config = %{ctx.config | credential: credential}

      assert {:ok, _receipt} = AzureServiceBus.deliver(config, prepared(), ctx.options)
      assert_received {:sent, _connection, request}
      assert header(request, "authorization") == signature
    end

    test "WH-17: a credential that is not a connection string is invalid", ctx do
      configs = [
        %{ctx.config | credential: Redacted.wrap("just-a-key")},
        %{ctx.config | credential: Redacted.wrap("SharedAccessKeyName=a;SharedAccessKey=")},
        %{ctx.config | credential: Redacted.wrap(:not_text)},
        Map.delete(ctx.config, :credential)
      ]

      for config <- configs do
        assert {:error, failure} = AzureServiceBus.deliver(config, prepared(), ctx.options)
        assert failure.class == :invalid
      end

      refute_received {:sent, _connection, _request}
    end

    test "WH-17: a namespace or an entity of the wrong form never becomes an address", ctx do
      configs = [
        %{ctx.config | namespace: "shop.servicebus.windows.net/x"},
        %{ctx.config | entity: "../other"},
        %{ctx.config | entity: ""},
        %{ctx.config | entity: "a//b"}
      ]

      for config <- configs do
        assert {:error, failure} = AzureServiceBus.deliver(config, prepared(), ctx.options)
        assert %{class: :invalid, reason: "entity_invalid"} = failure
      end

      refute_received {:sent, _connection, _request}
    end
  end

  describe "WH-17 managed identity" do
    test "WH-17: the caller's identity function gives the bearer token", ctx do
      config = Map.delete(ctx.config, :credential)
      config = Map.put(config, :managed_identity_client_id, @client_id)
      options = Keyword.put(ctx.options, :managed_identity, &identity/2)

      assert {:ok, _receipt} = AzureServiceBus.deliver(config, prepared(), options)

      assert_received {:identity, @client_id, "https://servicebus.azure.net"}
      assert_received {:sent, _connection, request}
      assert header(request, "authorization") == "Bearer bearer-1"
    end

    test "WH-17: without an identity function the identity is not available", ctx do
      config = Map.put(ctx.config, :managed_identity_client_id, @client_id)

      assert {:error, failure} = AzureServiceBus.deliver(config, prepared(), ctx.options)
      assert %{class: :credentials, reason: "managed_identity_unavailable"} = failure
      assert %Outcome{result: :retry} = Outcome.classify({:error, failure}, now())
      refute_received {:sent, _connection, _request}
    end

    test "WH-17: a failure of the identity function is the failure of the attempt", ctx do
      refused = %{class: :credentials, reason: "identity_refused", duration_ms: 3, address: nil}
      Process.put(:identity, {:error, refused})
      config = Map.put(ctx.config, :managed_identity_client_id, @client_id)
      options = Keyword.put(ctx.options, :managed_identity, &identity/2)

      assert AzureServiceBus.deliver(config, prepared(), options) == {:error, refused}
      refute_received {:sent, _connection, _request}
    end
  end

  describe "WH-8 CloudEvents mode" do
    test "WH-8: binary mode is the default: data in the body, attributes as properties", ctx do
      message = prepared(%{subject: "order o-1"})

      assert {:ok, _receipt} = AzureServiceBus.deliver(ctx.config, message, ctx.options)
      assert_received {:sent, _connection, request}

      assert request.body == ~s({"order_id":"o-1"})
      assert header(request, "content-type") == "application/json"
      assert header(request, "cloudEvents_specversion") == "1.0"
      assert header(request, "cloudEvents_id") == "evt_1"
      assert header(request, "cloudEvents_type") == "order.shipped"
      assert header(request, "cloudEvents_source") == "https://shop.example/orders"
      assert header(request, "cloudEvents_subject") == "order%20o-1"
      assert header(request, "cloudEvents_datacontenttype") == nil
    end

    test "WH-8: structured mode puts the whole event in the body", ctx do
      config = Map.put(ctx.config, :cloudevents_mode, "structured")
      message = prepared()

      assert {:ok, _receipt} = AzureServiceBus.deliver(config, message, ctx.options)
      assert_received {:sent, _connection, request}

      assert request.body == message.body
      assert header(request, "content-type") == "application/cloudevents+json; charset=utf-8"
      assert header(request, "cloudEvents_id") == nil
      assert properties(request)["MessageId"] == "evt_1"
    end
  end

  describe "WH-20 ordering and WH-18 deduplication" do
    test "WH-20: the subject is the session and the id is the message id", ctx do
      assert {:ok, _receipt} = AzureServiceBus.deliver(ctx.config, prepared(), ctx.options)
      assert_received {:sent, _connection, first}

      message = prepared(%{id: "evt_2", seq: 8})
      assert {:ok, _receipt} = AzureServiceBus.deliver(ctx.config, message, ctx.options)
      assert_received {:sent, _connection, second}

      assert properties(first) == %{"MessageId" => "evt_1", "SessionId" => "order/o-1"}
      assert properties(second) == %{"MessageId" => "evt_2", "SessionId" => "order/o-1"}
    end

    test "AG-24: a subject outside ASCII is still one session and a valid header", ctx do
      message = prepared(%{subject: "sipariş/1"})

      assert {:ok, _receipt} = AzureServiceBus.deliver(ctx.config, message, ctx.options)
      assert_received {:sent, _connection, request}

      assert header(request, "brokerproperties") =~ ~r/\A[\x20-\x7E]+\z/
      assert properties(request)["SessionId"] == "sipariş/1"
    end

    test "WH-20: an event without a subject has no session", ctx do
      message = prepared(%{subject: nil})

      assert {:ok, _receipt} = AzureServiceBus.deliver(ctx.config, message, ctx.options)
      assert_received {:sent, _connection, request}
      assert properties(request) == %{"MessageId" => "evt_1"}
    end
  end

  describe "WH-18 failures" do
    test "WH-18: the answers of the namespace are classified", ctx do
      cases = [
        {400, :rejected, :dead_lettered},
        {404, :rejected, :dead_lettered},
        {401, :credentials, :retry},
        {429, :unavailable, :retry},
        {500, :unavailable, :retry}
      ]

      for {status, class, result} <- cases do
        answer(@host, response(status, "<Error/>"))

        assert {:error, failure} = AzureServiceBus.deliver(ctx.config, prepared(), ctx.options)
        assert %{class: ^class, address: "203.0.114.10"} = failure
        assert %Outcome{result: ^result} = Outcome.classify({:error, failure}, now())
      end
    end
  end

  describe "WH-43 egress rules" do
    test "WH-43: a namespace that resolves to a blocked address is never called", ctx do
      resolve(@host, {:ok, [{172, 16, 0, 9}]})

      assert {:error, failure} = AzureServiceBus.deliver(ctx.config, prepared(), ctx.options)
      assert %{class: :blocked, address: "172.16.0.9"} = failure
      assert %Outcome{result: :dead_lettered} = Outcome.classify({:error, failure}, now())
      refute_received {:sent, _connection, _request}
    end

    test "WH-43: the address inside the connection string is never used", ctx do
      assert {:ok, _receipt} = AzureServiceBus.deliver(ctx.config, prepared(), ctx.options)

      assert_received {:sent, %{host: @host}, _request}
      refute_received {:sent, %{host: "other.servicebus.windows.net"}, _request}
    end
  end

  describe "WH-19 credentials" do
    test "WH-19: neither the key nor the signature appears in a failure", ctx do
      answer(@host, response(401, "denied"))

      assert {:error, failure} = AzureServiceBus.deliver(ctx.config, prepared(), ctx.options)

      refute inspect(failure) =~ ctx.access
      refute inspect(failure) =~ "SharedAccessSignature"
      refute inspect(ctx.config) =~ ctx.access
    end
  end
end
