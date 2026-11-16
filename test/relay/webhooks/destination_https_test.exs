defmodule Relay.Webhooks.DestinationHttpsTest.FakeResolver do
  @behaviour Relay.Webhooks.Egress.Resolver

  @impl Relay.Webhooks.Egress.Resolver
  def resolve(host, _timeout_ms), do: Process.get({:dns, host}, {:ok, [{203, 0, 114, 10}]})
end

defmodule Relay.Webhooks.DestinationHttpsTest.FakeTransport do
  @behaviour Relay.Webhooks.Egress.Transport

  @ok {:ok, %{status: 200, headers: [], body: "received", truncated: false}}

  @impl Relay.Webhooks.Egress.Transport
  def request(connection, request) do
    send(self(), {:sent, connection, request})
    Process.get({:answer, connection.host}, @ok)
  end
end

defmodule Relay.Webhooks.DestinationHttpsTest do
  use ExUnit.Case, async: true

  alias Relay.Redacted
  alias Relay.Webhooks.Destination
  alias Relay.Webhooks.Destination.Https
  alias Relay.Webhooks.DestinationHttpsTest.FakeResolver
  alias Relay.Webhooks.DestinationHttpsTest.FakeTransport
  alias Relay.Webhooks.Egress.Policy
  alias Relay.Webhooks.Envelope
  alias Relay.Webhooks.Outcome
  alias Relay.Webhooks.Profile

  @now ~U[2026-11-16 08:00:00Z]
  @timestamp DateTime.to_unix(@now)
  @url "https://hooks.example.com/relay"
  @token_url "https://login.example.com/oauth/token"
  @token_answer ~s({"access_token":"tok-1","token_type":"Bearer","expires_in":3600})

  setup do
    {:ok, policy} = Policy.new(deployment: :saas)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    options = [
      policy: policy,
      connect_timeout_ms: 5_000,
      total_timeout_ms: 20_000,
      max_response_bytes: 8_192,
      resolver: FakeResolver,
      transport: FakeTransport,
      token_cache: &cache/1
    ]

    %{options: options, key: {:ed25519, public}, private: private}
  end

  defp cache(fetch) do
    case Process.get(:token) do
      nil -> fetched(fetch.())
      token -> {:ok, token}
    end
  end

  defp fetched({:ok, token, lifetime}) do
    Process.put(:token, token)
    send(self(), {:cached, lifetime})
    {:ok, token}
  end

  defp fetched({:error, failure}), do: {:error, failure}

  defp prepared(private, attempt, type \\ "order.shipped") do
    fields = %{
      id: "evt_1",
      source: "https://shop.example/orders",
      type: type,
      time: @now,
      subject: "order/o-1",
      data: %{"order_id" => "o-1"}
    }

    {:ok, envelope} = Envelope.new(:destination, fields)
    body = Envelope.encode(envelope)
    content = Profile.signed_content("evt_1", @timestamp, body)
    token = Profile.token(:v1a, :crypto.sign(:eddsa, :none, content, [private, :ed25519]))
    Destination.prepare(envelope, body, Profile.headers("evt_1", @timestamp, [token]), attempt)
  end

  defp oauth2 do
    %{
      token_url: @token_url,
      client_id: "relay client",
      client_secret: Redacted.wrap("s3cr3t"),
      scope: "hooks.write"
    }
  end

  defp token_endpoint(answer), do: Process.put({:answer, "login.example.com"}, answer)

  defp token_response(status, body),
    do: {:ok, %{status: status, headers: [], body: body, truncated: false}}

  describe "WH-17 HTTPS destination" do
    test "WH-17: a delivery posts the structured body with the signed profile headers", ctx do
      prepared = prepared(ctx.private, 2)

      assert {:ok, receipt} = Https.deliver(%{url: @url}, prepared, ctx.options)
      assert %{kind: :http, status: 200, body: "received", truncated: false} = receipt
      assert %{address: "203.0.114.10", duration_ms: duration_ms} = receipt
      assert duration_ms >= 0

      assert_received {:sent, connection, request}
      assert %{address: {203, 0, 114, 10}, host: "hooks.example.com", port: 443} = connection
      assert connection.client_certificate == nil
      assert %{method: "POST", path: "/relay"} = request
      assert request.body == prepared.body
      assert {"content-type", "application/cloudevents+json; charset=utf-8"} in request.headers
      assert {"user-agent", "Suiss-Webhooks/1"} in request.headers
      refute List.keymember?(request.headers, "authorization", 0)

      assert {:ok, %{id: "evt_1", scheme: :v1a}} =
               Profile.verify(request.headers, request.body, [ctx.key], @now, 300)

      refute_received {:sent, _connection, _request}
    end

    test "WH-17: the prepared message carries binary mode and the ordering key", ctx do
      prepared = prepared(ctx.private, 1)

      assert prepared.partition_key == "order/o-1"
      assert prepared.data == ~s({"order_id":"o-1"})
      assert {"type", "order.shipped"} in prepared.attributes
      assert {"id", "evt_1"} in prepared.attributes
      assert Jason.decode!(prepared.body)["data"] == %{"order_id" => "o-1"}
      assert prepared.content_type == Envelope.content_type()
    end

    test "WH-17: the client certificate of mutual TLS reaches the boundary", ctx do
      certificate = %{certificate: <<1, 2, 3>>, key: Redacted.wrap({:ECPrivateKey, <<4>>})}
      config = %{url: @url, client_certificate: certificate}

      assert {:ok, %{status: 200}} = Https.deliver(config, prepared(ctx.private, 1), ctx.options)
      assert_received {:sent, %{client_certificate: ^certificate}, _request}
    end
  end

  describe "WH-9 unsigned convenience headers" do
    test "WH-9: the event type and the attempt number are sent, outside the signature", ctx do
      assert {:ok, _receipt} = Https.deliver(%{url: @url}, prepared(ctx.private, 7), ctx.options)
      assert_received {:sent, _connection, request}

      assert {"webhook-event-type", "order.shipped"} in request.headers
      assert {"webhook-attempt", "7"} in request.headers

      tampered = List.keyreplace(request.headers, "webhook-attempt", 0, {"webhook-attempt", "1"})
      assert {:ok, _verified} = Profile.verify(tampered, request.body, [ctx.key], @now, 300)
    end

    test "WH-9: an event type that cannot be a header value is left out", ctx do
      prepared = prepared(ctx.private, 1, "sipariş.kargolandı")

      assert {:ok, %{status: 200}} = Https.deliver(%{url: @url}, prepared, ctx.options)
      assert_received {:sent, _connection, request}
      refute List.keymember?(request.headers, "webhook-event-type", 0)
      assert {"webhook-attempt", "1"} in request.headers
    end
  end

  describe "WH-18 WH-23 receipts and failures" do
    test "WH-23: the receipt of any status is what the outcome is decided from", ctx do
      prepared = prepared(ctx.private, 1)
      headers = [{"retry-after", "30"}]
      answer = %{status: 503, headers: headers, body: "busy", truncated: false}
      Process.put({:answer, "hooks.example.com"}, {:ok, answer})

      result = Https.deliver(%{url: @url}, prepared, ctx.options)
      assert {:ok, %{kind: :http, status: 503, headers: ^headers, body: "busy"}} = result

      assert %Outcome{result: :retry, retry_after_ms: 30_000, status: 503} =
               Outcome.classify(result, @now)
    end

    test "WH-23: a blocked or unreachable destination is a failure with its class", ctx do
      prepared = prepared(ctx.private, 1)
      Process.put({:dns, "hooks.example.com"}, {:ok, [{10, 0, 0, 5}]})

      result = Https.deliver(%{url: @url}, prepared, ctx.options)
      assert {:error, %{class: :blocked, reason: "private", address: "10.0.0.5"}} = result
      assert %Outcome{result: :dead_lettered, endpoint: :warn} = Outcome.classify(result, @now)
      refute_received {:sent, _connection, _request}

      Process.put({:dns, "hooks.example.com"}, {:ok, [{203, 0, 114, 10}]})
      timeout = {:error, %{class: :timeout, reason: "timeout"}}
      Process.put({:answer, "hooks.example.com"}, timeout)

      result = Https.deliver(%{url: @url}, prepared, ctx.options)
      assert {:error, %{class: :timeout, address: "203.0.114.10", duration_ms: _ms}} = result
      assert %Outcome{result: :retry, reason: :timeout} = Outcome.classify(result, @now)

      result = Https.deliver(%{url: "http://hooks.example.com/"}, prepared, ctx.options)
      assert {:error, %{class: :invalid, reason: "scheme_not_https"}} = result
      assert %Outcome{result: :dead_lettered} = Outcome.classify(result, @now)
    end
  end

  describe "WH-17 WH-43 OAuth2 client credentials" do
    test "WH-17: the token is fetched through the boundary and cached by the caller", ctx do
      token_endpoint(token_response(200, @token_answer))
      config = %{url: @url, oauth2: oauth2()}

      assert {:ok, %{status: 200}} = Https.deliver(config, prepared(ctx.private, 1), ctx.options)
      assert_received {:cached, 3600}

      assert_received {:sent, %{host: "login.example.com"} = token_connection, token_request}
      assert token_connection.client_certificate == nil
      assert %{method: "POST", path: "/oauth/token"} = token_request
      assert token_request.body == "grant_type=client_credentials&scope=hooks.write"
      basic = "Basic " <> Base.encode64("relay+client:s3cr3t")
      assert {"authorization", basic} in token_request.headers
      assert {"content-type", "application/x-www-form-urlencoded"} in token_request.headers

      assert_received {:sent, %{host: "hooks.example.com"}, request}
      assert {"authorization", "Bearer tok-1"} in request.headers

      assert {:ok, %{status: 200}} = Https.deliver(config, prepared(ctx.private, 2), ctx.options)
      assert_received {:sent, %{host: "hooks.example.com"}, _request}
      refute_received {:sent, _connection, _request}
      refute_received {:cached, _lifetime}
    end

    test "WH-43: the token endpoint is held to the same address rules as the endpoint", ctx do
      Process.put({:dns, "login.example.com"}, {:ok, [{169, 254, 169, 254}]})
      config = %{url: @url, oauth2: oauth2()}

      assert {:error, %{class: :blocked, reason: "cloud_metadata"}} =
               Https.deliver(config, prepared(ctx.private, 1), ctx.options)

      refute_received {:sent, _connection, _request}

      plain = %{oauth2() | token_url: "http://login.example.com/oauth/token"}

      assert {:error, %{class: :invalid, reason: "scheme_not_https"}} =
               Https.deliver(%{url: @url, oauth2: plain}, prepared(ctx.private, 1), ctx.options)

      refute_received {:sent, _connection, _request}
    end

    test "WH-19: a token request that fails is a credentials failure that names no secret", ctx do
      config = %{url: @url, oauth2: oauth2()}
      prepared = prepared(ctx.private, 1)

      refused = ~s({"error":"invalid_client","hint":"s3cr3t"})
      other_type = ~s({"access_token":"tok-1","token_type":"mac"})

      answers = [
        {token_response(401, refused), "token_endpoint_refused"},
        {token_response(200, "tok-1 s3cr3t"), "token_response_invalid"},
        {token_response(200, other_type), "token_type_unsupported"},
        {token_response(200, ~s({"access_token":""})), "token_response_invalid"},
        {{:error, %{class: :timeout, reason: "timeout"}}, "token_endpoint_timeout"}
      ]

      for {answer, reason} <- answers do
        token_endpoint(answer)

        result = Https.deliver(config, prepared, ctx.options)
        assert {:error, %{class: :credentials, reason: ^reason} = failure} = result
        refute inspect(failure) =~ "s3cr3t"
        refute inspect(failure) =~ "tok-1"
        assert %Outcome{result: :retry, breaker: :neutral} = Outcome.classify(result, @now)
      end

      refute_received {:sent, %{host: "hooks.example.com"}, _request}
      refute inspect(config) =~ "s3cr3t"
    end
  end
end
