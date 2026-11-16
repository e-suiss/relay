defmodule Relay.Webhooks.Destination.GcpPubsubTest do
  use ExUnit.Case, async: true

  import RelayTest.DestinationFixture

  alias Relay.Redacted
  alias Relay.Webhooks.Destination.GcpPubsub
  alias Relay.Webhooks.Outcome

  @host "pubsub.googleapis.com"
  @token_host "oauth2.googleapis.com"
  @email "relay@shop-prod-1.iam.gserviceaccount.com"
  @token_answer ~s({"access_token":"tok-1","token_type":"Bearer","expires_in":3599})

  setup_all do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    public = {:RSAPublicKey, elem(key, 2), elem(key, 3)}
    %{pem: pem, public: public}
  end

  setup ctx do
    answer(@token_host, response(200, @token_answer))
    answer(@host, response(200, ~s({"messageIds":["1"]})))

    account = %{
      "type" => "service_account",
      "client_email" => @email,
      "private_key_id" => "key-1",
      "private_key" => ctx.pem
    }

    config = %{
      project_id: "shop-prod-1",
      topic: "orders",
      credential: Redacted.wrap(Jason.encode!(account))
    }

    %{config: config, options: options(token_cache: &cache/1, assertion_ttl_s: 600)}
  end

  defp published do
    assert_received {:sent, %{host: @host} = connection, request}
    %{"messages" => [message]} = Jason.decode!(request.body)
    {connection, request, message}
  end

  defp segment(text), do: text |> Base.url_decode64!(padding: false) |> Jason.decode!()

  describe "WH-18 success" do
    test "WH-18: the 2xx answer of publish is the acknowledged write", ctx do
      assert {:ok, receipt} = GcpPubsub.deliver(ctx.config, prepared(), ctx.options)
      assert %{kind: :write, status: 200, address: "203.0.114.10"} = receipt
      assert %Outcome{result: :delivered} = Outcome.classify({:ok, receipt}, now())

      {connection, request, _message} = published()
      assert %{port: 443, address: {203, 0, 114, 10}} = connection
      assert %{method: "POST", path: "/v1/projects/shop-prod-1/topics/orders:publish"} = request
      assert header(request, "authorization") == "Bearer tok-1"
      assert header(request, "content-type") == "application/json"
    end
  end

  describe "WH-17 service account" do
    test "WH-17: a JWT signed with the account key is exchanged for the token", ctx do
      assert {:ok, _receipt} = GcpPubsub.deliver(ctx.config, prepared(), ctx.options)

      assert_received {:sent, %{host: @token_host, port: 443}, request}
      assert %{method: "POST", path: "/token"} = request
      form = URI.decode_query(request.body)
      assert form["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"

      [header, claims, signature] = String.split(form["assertion"], ".")
      assert segment(header) == %{"alg" => "RS256", "typ" => "JWT", "kid" => "key-1"}

      issued = DateTime.to_unix(now())
      claims_map = segment(claims)
      assert claims_map["iss"] == @email
      assert claims_map["aud"] == "https://oauth2.googleapis.com/token"
      assert claims_map["scope"] == "https://www.googleapis.com/auth/pubsub"
      assert claims_map["iat"] == issued
      assert claims_map["exp"] == issued + 600

      signed = header <> "." <> claims
      raw = Base.url_decode64!(signature, padding: false)
      assert :public_key.verify(signed, :sha256, raw, ctx.public)
      assert_received {:cached, 3_599}
    end

    test "WH-17: the token is fetched once and reused from the caller's cache", ctx do
      assert {:ok, _receipt} = GcpPubsub.deliver(ctx.config, prepared(), ctx.options)
      assert {:ok, _receipt} = GcpPubsub.deliver(ctx.config, prepared(), ctx.options)

      assert_received {:sent, %{host: @token_host}, _request}
      refute_received {:sent, %{host: @token_host}, _request}
      assert_received {:sent, %{host: @host}, _request}
      assert_received {:sent, %{host: @host}, _request}
    end

    test "WH-17: a refused token request means the credentials are not available", ctx do
      answer(@token_host, response(400, ~s({"error":"invalid_grant"})))

      assert {:error, failure} = GcpPubsub.deliver(ctx.config, prepared(), ctx.options)
      assert %{class: :credentials, reason: "token_endpoint_http_400"} = failure
      assert %Outcome{result: :retry} = Outcome.classify({:error, failure}, now())
      refute_received {:sent, %{host: @host}, _request}
      refute_received {:cached, _lifetime}
    end

    test "WH-17: a token answer without a token is not used", ctx do
      answer(@token_host, response(200, ~s({"token_type":"Bearer"})))

      assert {:error, failure} = GcpPubsub.deliver(ctx.config, prepared(), ctx.options)
      assert %{class: :credentials, reason: "token_response_invalid"} = failure
    end

    test "WH-17: a credential that is not a service account key is invalid", ctx do
      configs = [
        %{ctx.config | credential: Redacted.wrap("not json")},
        %{ctx.config | credential: Redacted.wrap(~s({"client_email":"a@b.c"}))},
        %{ctx.config | credential: Redacted.wrap(~s({"client_email":"a@b.c","private_key":"x"}))},
        Map.delete(ctx.config, :credential)
      ]

      for config <- configs do
        assert {:error, %{class: :invalid}} = GcpPubsub.deliver(config, prepared(), ctx.options)
      end

      refute_received {:sent, _connection, _request}
    end

    test "WH-17: a project or a topic of the wrong form never becomes a path", ctx do
      configs = [
        %{ctx.config | project_id: "x/../y"},
        %{ctx.config | topic: "orders/../../other"},
        %{ctx.config | topic: "o"}
      ]

      for config <- configs do
        assert {:error, failure} = GcpPubsub.deliver(config, prepared(), ctx.options)
        assert %{class: :invalid, reason: "topic_invalid"} = failure
      end

      refute_received {:sent, _connection, _request}
    end
  end

  describe "WH-8 CloudEvents mode" do
    test "WH-8: binary mode is the default: data in the message, attributes beside it", ctx do
      assert {:ok, _receipt} = GcpPubsub.deliver(ctx.config, prepared(), ctx.options)

      {_connection, _request, message} = published()
      attributes = message["attributes"]

      assert Base.decode64!(message["data"]) == ~s({"order_id":"o-1"})
      assert attributes["ce-specversion"] == "1.0"
      assert attributes["ce-id"] == "evt_1"
      assert attributes["ce-type"] == "order.shipped"
      assert attributes["ce-source"] == "https://shop.example/orders"
      assert attributes["ce-subject"] == "order/o-1"
      assert attributes["ce-seq"] == "7"
      assert attributes["content-type"] == "application/json"
      refute Map.has_key?(attributes, "ce-datacontenttype")
    end

    test "WH-8: structured mode puts the whole event in the message", ctx do
      config = Map.put(ctx.config, :cloudevents_mode, "structured")
      message = prepared()

      assert {:ok, _receipt} = GcpPubsub.deliver(config, message, ctx.options)

      {_connection, _request, published} = published()
      content_type = "application/cloudevents+json; charset=utf-8"
      assert Base.decode64!(published["data"]) == message.body
      assert published["attributes"] == %{"content-type" => content_type, "ce-id" => "evt_1"}
    end
  end

  describe "WH-20 ordering and WH-18 deduplication" do
    test "WH-20: the subject is the ordering key and the id is an attribute", ctx do
      assert {:ok, _receipt} = GcpPubsub.deliver(ctx.config, prepared(), ctx.options)
      {_connection, _request, first} = published()

      message = prepared(%{id: "evt_2", seq: 8})
      assert {:ok, _receipt} = GcpPubsub.deliver(ctx.config, message, ctx.options)
      {_connection, _request, second} = published()

      assert first["orderingKey"] == "order/o-1"
      assert second["orderingKey"] == "order/o-1"
      assert first["attributes"]["ce-id"] == "evt_1"
      assert second["attributes"]["ce-id"] == "evt_2"
    end

    test "AG-24: an event without a subject has no ordering key", ctx do
      message = prepared(%{subject: nil})

      assert {:ok, _receipt} = GcpPubsub.deliver(ctx.config, message, ctx.options)
      {_connection, _request, published} = published()
      refute Map.has_key?(published, "orderingKey")
    end
  end

  describe "WH-18 failures" do
    test "WH-18: the answers of the API are classified", ctx do
      cases = [
        {400, :rejected, :dead_lettered},
        {404, :rejected, :dead_lettered},
        {403, :credentials, :retry},
        {429, :unavailable, :retry},
        {503, :unavailable, :retry}
      ]

      for {status, class, result} <- cases do
        answer(@host, response(status, "{}"))

        assert {:error, failure} = GcpPubsub.deliver(ctx.config, prepared(), ctx.options)
        assert %{class: ^class, address: "203.0.114.10"} = failure
        assert %Outcome{result: ^result} = Outcome.classify({:error, failure}, now())
      end
    end
  end

  describe "WH-43 egress rules" do
    test "WH-43: an API host that resolves to a blocked address is never called", ctx do
      resolve(@host, {:ok, [{10, 0, 0, 1}]})

      assert {:error, failure} = GcpPubsub.deliver(ctx.config, prepared(), ctx.options)
      assert %{class: :blocked, address: "10.0.0.1"} = failure
      assert %Outcome{result: :dead_lettered} = Outcome.classify({:error, failure}, now())
      refute_received {:sent, %{host: @host}, _request}
    end

    test "WH-43: the token request goes through the egress rules as well", ctx do
      resolve(@token_host, {:ok, [{169, 254, 169, 254}]})

      assert {:error, failure} = GcpPubsub.deliver(ctx.config, prepared(), ctx.options)
      assert %{class: :blocked, address: "169.254.169.254"} = failure
      refute_received {:sent, _connection, _request}
    end
  end

  describe "WH-19 credentials" do
    test "WH-19: neither the key nor the token appears in a failure or in the cache", ctx do
      answer(@host, response(403, "denied"))

      assert {:error, failure} = GcpPubsub.deliver(ctx.config, prepared(), ctx.options)

      refute inspect(failure) =~ "tok-1"
      refute inspect(failure) =~ "PRIVATE KEY"
      refute inspect(ctx.config) =~ "PRIVATE KEY"
      refute inspect(Process.get(:cached_token)) =~ "tok-1"
    end
  end
end
