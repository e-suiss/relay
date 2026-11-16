defmodule Relay.Webhooks.Destination.RabbitmqTest.FakeResolver do
  @behaviour Relay.Webhooks.Egress.Resolver

  @impl Relay.Webhooks.Egress.Resolver
  def resolve(host, _timeout_ms), do: Process.get({:dns, host}, {:ok, [{203, 0, 114, 10}]})
end

defmodule Relay.Webhooks.Destination.RabbitmqTest do
  use ExUnit.Case, async: true

  alias Relay.Redacted
  alias Relay.Webhooks.Destination
  alias Relay.Webhooks.Destination.Rabbitmq
  alias Relay.Webhooks.Destination.RabbitmqTest.FakeResolver
  alias Relay.Webhooks.Egress.Policy
  alias Relay.Webhooks.Envelope
  alias Relay.Webhooks.Outcome
  alias RelayTest.ScriptedSocket

  @now ~U[2026-11-16 08:00:00Z]
  @host "mq.example.com"
  @frame_end 0xCE

  setup do
    {:ok, policy} = Policy.new(deployment: :saas, extra_ports: [5671])

    options = [
      policy: policy,
      connect_timeout_ms: 5_000,
      total_timeout_ms: 20_000,
      max_frame_bytes: 131_072,
      resolver: FakeResolver,
      dialer: ScriptedSocket
    ]

    %{options: options}
  end

  defp config(extra \\ %{}) do
    base = %{
      host: @host <> ":5671",
      exchange: "events",
      routing_key: "orders.shipped",
      username: "relay",
      credential: Redacted.wrap("s3cr3t-pass")
    }

    Map.merge(base, extra)
  end

  defp prepared(data \\ %{"order_id" => "o-1"}) do
    fields = %{
      id: "evt_1",
      source: "https://shop.example/orders",
      type: "order.shipped",
      time: @now,
      subject: "order/o-1",
      data: data
    }

    {:ok, envelope} = Envelope.new(:destination, fields)
    Destination.prepare(envelope, Envelope.encode(envelope), [], 1)
  end

  defp broker(overrides \\ %{}) do
    defaults = %{
      mechanisms: "PLAIN AMQPLAIN EXTERNAL",
      auth: tune(131_072),
      open: method(0, <<10::16, 41::16, 0>>),
      confirm: ack()
    }

    state = %{replies: Map.merge(defaults, overrides), size: nil, body: ""}
    ScriptedSocket.serve(@host, &serve/2, state)
  end

  defp frame(type, channel, payload),
    do: <<type, channel::16, byte_size(payload)::32, payload::binary, @frame_end>>

  defp method(channel, payload), do: frame(1, channel, payload)

  defp start(mechanisms) do
    size = byte_size(mechanisms)
    method(0, <<10::16, 10::16, 0, 9, 0::32, size::32, mechanisms::binary, 5::32, "en_US">>)
  end

  defp tune(frame_max), do: method(0, <<10::16, 30::16, 2047::16, frame_max::32, 60::16>>)
  defp ack, do: method(1, <<60::16, 80::16, 1::64, 0>>)
  defp nack, do: method(1, <<60::16, 120::16, 1::64, 0>>)
  defp returned, do: method(1, <<60::16, 50::16, 312::16, 8, "NO_ROUTE", 6, "events", 0>>)

  defp connection_close(code, text),
    do: method(0, <<10::16, 50::16, code::16, byte_size(text), text::binary, 0::16, 0::16>>)

  defp channel_close(code, text),
    do: method(1, <<20::16, 40::16, code::16, byte_size(text), text::binary, 60::16, 40::16>>)

  defp serve(:open, state), do: {"", state}

  defp serve({:data, <<"AMQP", version::binary-size(4)>>}, state) do
    send(self(), {:amqp, :protocol, version})
    {start(state.replies.mechanisms), state}
  end

  defp serve({:data, data}, state) do
    Enum.reduce(frames(data), {[], state}, fn frame, {answers, state} ->
      {answer, state} = handle(frame, state)
      {[answers, answer], state}
    end)
  end

  defp frames(<<>>), do: []

  defp frames(<<type, channel::16, size::32, payload::binary-size(size), rest::binary>>) do
    <<@frame_end, rest::binary>> = rest
    [{type, channel, payload} | frames(rest)]
  end

  defp handle({1, 0, <<10::16, 11::16, rest::binary>>}, state) do
    <<size::32, properties::binary-size(size), rest::binary>> = rest
    <<length, mechanism::binary-size(length), rest::binary>> = rest
    <<bytes::32, response::binary-size(bytes), 5, "en_US">> = rest
    send(self(), {:amqp, :start_ok, mechanism, response, table(properties)})
    {state.replies.auth, state}
  end

  defp handle({1, 0, <<10::16, 31::16, channel_max::16, frame_max::32, heartbeat::16>>}, state) do
    send(self(), {:amqp, :tune_ok, channel_max, frame_max, heartbeat})
    {"", state}
  end

  defp handle({1, 0, <<10::16, 40::16, size, vhost::binary-size(size), 0, 0>>}, state) do
    send(self(), {:amqp, :open, vhost})
    {state.replies.open, state}
  end

  defp handle({1, 0, <<10::16, 50::16, code::16, _rest::binary>>}, state) do
    send(self(), {:amqp, :close, code})
    {method(0, <<10::16, 51::16>>), state}
  end

  defp handle({1, 1, <<20::16, 10::16, 0>>}, state) do
    send(self(), {:amqp, :channel_open})
    {method(1, <<20::16, 11::16, 0::32>>), state}
  end

  defp handle({1, 1, <<85::16, 10::16, 0>>}, state) do
    send(self(), {:amqp, :confirm_select})
    {method(1, <<85::16, 11::16>>), state}
  end

  defp handle({1, 1, <<60::16, 40::16, 0::16, rest::binary>>}, state) do
    <<size, exchange::binary-size(size), rest::binary>> = rest
    <<length, routing_key::binary-size(length), bits>> = rest
    send(self(), {:amqp, :publish, exchange, routing_key, bits})
    {"", state}
  end

  defp handle({2, 1, <<60::16, 0::16, size::64, flags::16, rest::binary>>}, state) do
    <<length, content_type::binary-size(length), rest::binary>> = rest
    <<bytes::32, headers::binary-size(bytes), delivery_mode, rest::binary>> = rest
    <<id_size, message_id::binary-size(id_size)>> = rest

    properties = %{
      content_type: content_type,
      headers: table(headers),
      delivery_mode: delivery_mode,
      message_id: message_id
    }

    send(self(), {:amqp, :header, flags, properties})
    complete(%{state | size: size})
  end

  defp handle({3, 1, chunk}, state) do
    send(self(), {:amqp, :body_frame, byte_size(chunk)})
    complete(%{state | body: state.body <> chunk})
  end

  defp complete(%{size: size, body: body} = state) when byte_size(body) == size do
    send(self(), {:amqp, :body, body})
    {state.replies.confirm, state}
  end

  defp complete(state), do: {"", state}

  defp table(<<>>), do: []

  defp table(<<size, name::binary-size(size), ?S, bytes::32, rest::binary>>) do
    <<value::binary-size(^bytes), rest::binary>> = rest
    [{name, value} | table(rest)]
  end

  defp table(<<size, name::binary-size(size), ?t, flag, rest::binary>>),
    do: [{name, flag == 1} | table(rest)]

  defp table(<<size, name::binary-size(size), ?F, bytes::32, rest::binary>>) do
    <<nested::binary-size(^bytes), rest::binary>> = rest
    [{name, table(nested)} | table(rest)]
  end

  defp client_chain do
    key = {:rsa, 2048, 65_537}

    %{client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: [key: key], intermediates: [], peer: [key: key]},
        client_chain: %{root: [key: key], intermediates: [], peer: [key: key]}
      })

    {type, der} = client[:key]

    %{
      certificate: client[:cert],
      certificate_pem: :public_key.pem_encode([{:Certificate, client[:cert], :not_encrypted}]),
      key: client[:key],
      key_pem: :public_key.pem_encode([{type, der, :not_encrypted}])
    }
  end

  describe "WH-17 authentication" do
    test "WH-17: a user name and its password authenticate with PLAIN over TLS", ctx do
      broker()

      assert {:ok, _receipt} = Rabbitmq.deliver(config(), prepared(), ctx.options)

      assert_received {:dialed, connection}
      assert %{address: {203, 0, 114, 10}, host: @host, port: 5671, mode: :tls} = connection
      assert connection.client_certificate == nil
      assert_received {:amqp, :protocol, <<0, 0, 9, 1>>}
      assert_received {:amqp, :start_ok, "PLAIN", <<0, "relay", 0, "s3cr3t-pass">>, properties}
      assert {"product", "suiss-relay"} in properties
      assert {"capabilities", capabilities} = List.keyfind(properties, "capabilities", 0)
      assert {"publisher_confirms", true} in capabilities
      assert {"authentication_failure_close", true} in capabilities
      assert_received {:amqp, :tune_ok, 1, 131_072, 0}
      assert_received {:amqp, :open, "/"}
      assert_received {:amqp, :channel_open}
      assert_received {:amqp, :close, 200}
      assert_received {:closed, @host}
      refute_received {:upgraded, _host}
    end

    test "WH-17: the virtual host of the configuration is opened", ctx do
      broker()

      assert {:ok, _receipt} =
               Rabbitmq.deliver(config(%{vhost: "tenant-a"}), prepared(), ctx.options)

      assert_received {:amqp, :open, "tenant-a"}
    end

    test "WH-17: a client certificate authenticates with EXTERNAL", ctx do
      broker()
      chain = client_chain()

      config = %{
        host: @host <> ":5671",
        exchange: "events",
        client_certificate: chain.certificate_pem,
        credential: Redacted.wrap(chain.key_pem)
      }

      assert {:ok, _receipt} = Rabbitmq.deliver(config, prepared(), ctx.options)

      assert_received {:dialed, %{client_certificate: certificate}}
      assert certificate.certificate == [chain.certificate]
      assert Redacted.expose(certificate.key) == chain.key
      assert_received {:amqp, :start_ok, "EXTERNAL", "", _properties}
      assert_received {:amqp, :publish, "events", "", 1}
    end

    test "WH-17: a decoded client certificate may accompany a password", ctx do
      broker()
      certificate = %{certificate: <<1, 2, 3>>, key: Redacted.wrap({:ECPrivateKey, <<4>>})}
      config = config(%{client_certificate: certificate})

      assert {:ok, _receipt} = Rabbitmq.deliver(config, prepared(), ctx.options)
      assert_received {:dialed, %{client_certificate: ^certificate}}
      assert_received {:amqp, :start_ok, "PLAIN", _response, _properties}
    end

    test "WH-17: a mechanism the broker does not offer is a credentials failure", ctx do
      broker(%{mechanisms: "AMQPLAIN"})

      assert {:error, %{class: :credentials, reason: "mechanism_not_offered"} = failure} =
               Rabbitmq.deliver(config(), prepared(), ctx.options)

      assert failure.address == "203.0.114.10"
      assert %Outcome{result: :retry, reason: :credentials_unavailable, breaker: :neutral} =
               Outcome.classify({:error, failure}, @now)

      refute_received {:amqp, :start_ok, _mechanism, _response, _properties}
      assert_received {:closed, @host}
    end

    test "WH-17: a login the broker refuses is a credentials failure", ctx do
      broker(%{auth: connection_close(403, "ACCESS_REFUSED")})

      assert {:error, %{class: :credentials, reason: "authentication_failed"}} =
               Rabbitmq.deliver(config(), prepared(), ctx.options)

      refute_received {:amqp, :publish, _exchange, _routing_key, _bits}
      assert_received {:closed, @host}
    end

    test "WH-17: a configuration that cannot be used is refused before any connection", ctx do
      broker()
      pem = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"

      configs = [
        Map.delete(config(), :exchange),
        Map.delete(config(), :credential),
        %{config() | credential: "s3cr3t-pass"},
        %{config() | host: "mq.example.com"},
        config(%{cloudevents_mode: "batch"}),
        config(%{routing_key: String.duplicate("k", 256)}),
        config(%{client_certificate: pem}),
        Map.drop(config(), [:username, :credential])
      ]

      for config <- configs do
        assert {:error, %{class: :invalid, address: nil} = failure} =
                 Rabbitmq.deliver(config, prepared(), ctx.options)

        assert %Outcome{result: :dead_lettered, reason: :destination_invalid} =
                 Outcome.classify({:error, failure}, @now)
      end

      refute_received {:dialed, _connection}
    end
  end

  describe "WH-18 publisher confirm" do
    test "WH-18: the confirm of the mandatory, persistent message is the success", ctx do
      broker()

      assert {:ok, receipt} = Rabbitmq.deliver(config(), prepared(), ctx.options)
      assert %{kind: :write, address: "203.0.114.10", duration_ms: duration_ms} = receipt
      assert duration_ms >= 0
      assert map_size(receipt) == 3

      assert %Outcome{result: :delivered, reason: :acknowledged, breaker: :success} =
               Outcome.classify({:ok, receipt}, @now)

      assert_received {:amqp, :confirm_select}
      assert_received {:amqp, :publish, "events", "orders.shipped", 1}
      assert_received {:amqp, :header, 0xB080, %{delivery_mode: 2}}
    end

    test "WH-18: the CloudEvents id is the message id a consumer deduplicates by", ctx do
      broker()

      assert {:ok, _receipt} = Rabbitmq.deliver(config(), prepared(), ctx.options)
      assert_received {:amqp, :header, _flags, %{message_id: "evt_1"}}
    end

    test "WH-18: a message no queue takes is rejected", ctx do
      broker(%{confirm: [returned(), ack()]})

      assert {:error, %{class: :rejected, reason: "unroutable"} = failure} =
               Rabbitmq.deliver(config(), prepared(), ctx.options)

      assert %Outcome{result: :dead_lettered, reason: :destination_rejected} =
               Outcome.classify({:error, failure}, @now)

      assert_received {:closed, @host}
    end

    test "WH-18: a nack means the broker did not take the message now", ctx do
      broker(%{confirm: nack()})

      assert {:error, %{class: :unavailable, reason: "nacked"} = failure} =
               Rabbitmq.deliver(config(), prepared(), ctx.options)

      assert %Outcome{result: :retry, reason: :destination_unavailable, breaker: :failure} =
               Outcome.classify({:error, failure}, @now)
    end

    test "WH-18: a close by the broker is classified by its reply code", ctx do
      cases = [
        {%{confirm: channel_close(404, "NOT_FOUND")}, :rejected, "amqp_404"},
        {%{confirm: channel_close(406, "PRECONDITION_FAILED")}, :rejected, "amqp_406"},
        {%{confirm: channel_close(403, "ACCESS_REFUSED")}, :credentials, "amqp_403"},
        {%{confirm: channel_close(311, "CONTENT_TOO_LARGE")}, :rejected, "amqp_311"},
        {%{confirm: connection_close(541, "INTERNAL_ERROR")}, :unavailable, "amqp_541"},
        {%{confirm: connection_close(320, "CONNECTION_FORCED")}, :unavailable, "amqp_320"},
        {%{open: connection_close(530, "NOT_ALLOWED")}, :rejected, "amqp_530"}
      ]

      for {overrides, class, reason} <- cases do
        broker(overrides)

        assert {:error, %{class: ^class, reason: ^reason, address: "203.0.114.10"}} =
                 Rabbitmq.deliver(config(), prepared(), ctx.options)
      end
    end

    test "WH-18: without a confirm the attempt ends as a timeout", ctx do
      broker(%{confirm: ""})

      assert {:error, %{class: :timeout} = failure} =
               Rabbitmq.deliver(config(), prepared(), ctx.options)

      assert %Outcome{result: :retry, reason: :timeout} =
               Outcome.classify({:error, failure}, @now)

      assert_received {:closed, @host}
    end

    test "WH-18: a body larger than a frame is split by the negotiated frame size", ctx do
      broker(%{auth: tune(4096)})
      prepared = prepared(%{"blob" => String.duplicate("a", 10_000)})

      assert {:ok, _receipt} = Rabbitmq.deliver(config(), prepared, ctx.options)

      assert_received {:amqp, :tune_ok, 1, 4096, 0}
      assert_received {:amqp, :body_frame, 4088}
      assert_received {:amqp, :body_frame, 4088}
      assert_received {:amqp, :body_frame, rest}
      assert rest == byte_size(prepared.data) - 2 * 4088
      refute_received {:amqp, :body_frame, _size}
      assert_received {:amqp, :body, body}
      assert body == prepared.data
    end

    test "WH-18: the frame size is never larger than the caller allows", ctx do
      broker()
      options = Keyword.put(ctx.options, :max_frame_bytes, 8_192)

      assert {:ok, _receipt} = Rabbitmq.deliver(config(), prepared(), options)
      assert_received {:amqp, :tune_ok, 1, 8_192, 0}
    end

    test "WH-18: a frame larger than the caller allows is a protocol error", ctx do
      broker(%{mechanisms: String.duplicate("PLAIN ", 2_000)})
      options = Keyword.put(ctx.options, :max_frame_bytes, 4_096)

      assert {:error, %{class: :protocol, reason: "frame_too_large"} = failure} =
               Rabbitmq.deliver(config(), prepared(), options)

      assert %Outcome{result: :retry, reason: :protocol_error} =
               Outcome.classify({:error, failure}, @now)

      assert_received {:closed, @host}
    end

    test "WH-18: an answer that is not the expected method is a protocol error", ctx do
      broker(%{open: ack()})

      assert {:error, %{class: :protocol, reason: "unexpected_frame"}} =
               Rabbitmq.deliver(config(), prepared(), ctx.options)
    end
  end

  describe "WH-8 CloudEvents binding" do
    test "WH-8: binary mode carries the attributes as headers and data as the body", ctx do
      broker()
      prepared = prepared()

      assert {:ok, _receipt} = Rabbitmq.deliver(config(), prepared, ctx.options)

      assert_received {:amqp, :header, _flags, properties}
      assert properties.content_type == "application/json"
      assert {"cloudEvents:specversion", "1.0"} in properties.headers
      assert {"cloudEvents:id", "evt_1"} in properties.headers
      assert {"cloudEvents:type", "order.shipped"} in properties.headers
      assert {"cloudEvents:source", "https://shop.example/orders"} in properties.headers
      assert {"cloudEvents:subject", "order/o-1"} in properties.headers
      refute List.keymember?(properties.headers, "cloudEvents:datacontenttype", 0)
      assert_received {:amqp, :body, body}
      assert body == prepared.data
      assert body == ~s({"order_id":"o-1"})
    end

    test "WH-8: structured mode carries the whole event as the body", ctx do
      broker()
      prepared = prepared()
      config = config(%{cloudevents_mode: "structured"})

      assert {:ok, _receipt} = Rabbitmq.deliver(config, prepared, ctx.options)

      assert_received {:amqp, :header, _flags, properties}
      assert properties.content_type == Envelope.content_type()
      assert properties.headers == [{"cloudEvents:id", "evt_1"}]
      assert properties.message_id == "evt_1"
      assert_received {:amqp, :body, body}
      assert body == prepared.body
    end
  end

  describe "WH-43 egress rules" do
    test "WH-43: a broker address in a blocked range is never connected", ctx do
      broker()
      Process.put({:dns, @host}, {:ok, [{203, 0, 114, 10}, {10, 0, 0, 1}]})

      assert {:error, %{class: :blocked, address: "10.0.0.1"} = failure} =
               Rabbitmq.deliver(config(), prepared(), ctx.options)

      assert %Outcome{result: :dead_lettered, reason: :destination_blocked, endpoint: :warn} =
               Outcome.classify({:error, failure}, @now)

      refute_received {:dialed, _connection}
    end

    test "WH-43: a literal loopback address and a metadata host are refused", ctx do
      for host <- ["127.0.0.1:5671", "metadata.google.internal:5671"] do
        assert {:error, %{class: :blocked}} =
                 Rabbitmq.deliver(config(%{host: host}), prepared(), ctx.options)
      end

      refute_received {:dialed, _connection}
    end

    test "WH-43: a port the installation does not allow is refused", ctx do
      broker()

      assert {:error, %{class: :invalid, reason: "port_not_allowed"}} =
               Rabbitmq.deliver(config(%{host: @host <> ":5672"}), prepared(), ctx.options)

      refute_received {:dialed, _connection}
    end

    test "WH-43: a broker that cannot be reached is a connection error", ctx do
      ScriptedSocket.refuse(@host, %{class: :connect, reason: "econnrefused"})

      assert {:error, %{class: :connect, reason: "econnrefused", address: "203.0.114.10"}} =
               Rabbitmq.deliver(config(), prepared(), ctx.options)
    end
  end

  describe "WH-19 credentials" do
    test "WH-19: the password appears in no failure and in no receipt", ctx do
      broker(%{auth: connection_close(403, "ACCESS_REFUSED - s3cr3t-pass")})

      assert {:error, failure} = Rabbitmq.deliver(config(), prepared(), ctx.options)
      refute inspect(failure) =~ "s3cr3t"

      broker()
      assert {:ok, receipt} = Rabbitmq.deliver(config(), prepared(), ctx.options)
      refute inspect(receipt) =~ "s3cr3t"
      refute inspect(config()) =~ "s3cr3t"
    end
  end
end
