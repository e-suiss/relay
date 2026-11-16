defmodule Relay.Webhooks.Destination.NatsJetstreamTest.FakeResolver do
  @behaviour Relay.Webhooks.Egress.Resolver

  @impl Relay.Webhooks.Egress.Resolver
  def resolve(host, _timeout_ms), do: Process.get({:dns, host}, {:ok, [{203, 0, 114, 10}]})
end

defmodule Relay.Webhooks.Destination.NatsJetstreamTest do
  use ExUnit.Case, async: true

  alias Relay.Redacted
  alias Relay.Webhooks.Destination
  alias Relay.Webhooks.Destination.NatsJetstream
  alias Relay.Webhooks.Destination.NatsJetstream.Nkey
  alias Relay.Webhooks.Destination.NatsJetstreamTest.FakeResolver
  alias Relay.Webhooks.Egress.Policy
  alias Relay.Webhooks.Envelope
  alias Relay.Webhooks.Outcome
  alias RelayTest.ScriptedSocket

  @now ~U[2026-11-16 08:00:00Z]
  @host "nats.example.com"
  @other "nats-2.example.com"
  @info %{"server_id" => "NTEST", "tls_required" => true, "headers" => true}

  setup do
    {:ok, policy} = Policy.new(deployment: :saas, extra_ports: [4222])

    options = [
      policy: policy,
      connect_timeout_ms: 5_000,
      total_timeout_ms: 20_000,
      max_frame_bytes: 65_536,
      resolver: FakeResolver,
      dialer: ScriptedSocket
    ]

    %{options: options}
  end

  defp config(extra \\ %{}) do
    base = %{
      servers: [@host <> ":4222"],
      subject: "orders.shipped",
      username: "relay",
      credential: Redacted.wrap("s3cr3t-pass")
    }

    Map.merge(base, extra)
  end

  defp anonymous(extra \\ %{}),
    do: Map.merge(%{servers: [@host <> ":4222"], subject: "orders.shipped"}, extra)

  defp prepared do
    fields = %{
      id: "evt_1",
      source: "https://shop.example/orders",
      type: "order.shipped",
      time: @now,
      subject: "order/o-1",
      data: %{"order_id" => "o-1"}
    }

    {:ok, envelope} = Envelope.new(:destination, fields)
    Destination.prepare(envelope, Envelope.encode(envelope), [], 1)
  end

  defp server(host \\ @host, overrides \\ %{}) do
    defaults = %{info: @info, pong: "PONG\r\n", ack: &ack/1, ponged: fn _inbox -> "" end}
    state = %{replies: Map.merge(defaults, overrides), inbox: nil}
    ScriptedSocket.serve(host, &serve/2, state)
  end

  defp ack(inbox), do: msg(inbox, ~s({"stream":"EVENTS","seq":42}))

  defp msg(inbox, payload),
    do: ["MSG ", inbox, " 1 ", Integer.to_string(byte_size(payload)), "\r\n", payload, "\r\n"]

  defp no_responders(inbox) do
    block = "NATS/1.0 503\r\n\r\n"
    size = Integer.to_string(byte_size(block))
    ["HMSG ", inbox, " 1 ", size, " ", size, "\r\n", block, "\r\n"]
  end

  defp refusal(code, err_code) do
    error = %{"code" => code, "err_code" => err_code, "description" => "refused"}
    fn inbox -> msg(inbox, Jason.encode!(%{"type" => "pub_ack", "error" => error})) end
  end

  defp serve(:open, state), do: {["INFO ", Jason.encode!(state.replies.info), "\r\n"], state}
  defp serve(:upgrade, state), do: {"", state}
  defp serve({:data, data}, state), do: commands(data, [], state)

  defp commands("", answers, state), do: {answers, state}

  defp commands(data, answers, state) do
    [line, rest] = :binary.split(data, "\r\n")
    {answer, rest, state} = command(String.split(line, " ", parts: 2), rest, state)
    commands(rest, [answers, answer], state)
  end

  defp command(["CONNECT", json], rest, state) do
    send(self(), {:nats, :connect, Jason.decode!(json)})
    {"", rest, state}
  end

  defp command(["SUB", arguments], rest, state) do
    [inbox, "1"] = String.split(arguments, " ")
    send(self(), {:nats, :sub, inbox})
    {"", rest, %{state | inbox: inbox}}
  end

  defp command(["PING"], rest, state), do: {state.replies.pong, rest, state}

  defp command(["PONG"], rest, state) do
    send(self(), {:nats, :pong})
    {state.replies.ponged.(state.inbox), rest, state}
  end

  defp command(["HPUB", arguments], rest, state) do
    [subject, reply, header_size, total_size] = String.split(arguments, " ")
    header_size = String.to_integer(header_size)
    payload_size = String.to_integer(total_size) - header_size
    <<block::binary-size(^header_size), rest::binary>> = rest
    <<payload::binary-size(^payload_size), "\r\n", rest::binary>> = rest
    send(self(), {:nats, :publish, subject, reply, headers(block), payload})
    {state.replies.ack.(state.inbox), rest, state}
  end

  defp headers("NATS/1.0\r\n" <> block) do
    true = String.ends_with?(block, "\r\n\r\n")

    for line <- String.split(block, "\r\n", trim: true) do
      [name, value] = String.split(line, ": ", parts: 2)
      {name, value}
    end
  end

  defp position(messages, match), do: Enum.find_index(messages, match)

  describe "WH-17 authentication" do
    test "WH-17: a user name and its password are sent after the TLS upgrade", ctx do
      server()

      assert {:ok, _receipt} = NatsJetstream.deliver(config(), prepared(), ctx.options)

      {:messages, messages} = Process.info(self(), :messages)
      dialed = position(messages, &match?({:dialed, _connection}, &1))
      upgraded = position(messages, &match?({:upgraded, @host}, &1))
      connected = position(messages, &match?({:nats, :connect, _fields}, &1))
      assert dialed < upgraded
      assert upgraded < connected

      assert_received {:dialed, connection}
      assert %{address: {203, 0, 114, 10}, host: @host, port: 4222, mode: :plain} = connection
      assert_received {:nats, :connect, fields}
      assert %{"user" => "relay", "pass" => "s3cr3t-pass", "tls_required" => true} = fields
      assert %{"headers" => true, "no_responders" => true, "verbose" => false} = fields
      assert %{"protocol" => 1, "lang" => "elixir", "name" => "suiss-relay"} = fields
      refute is_map_key(fields, "auth_token")
      refute is_map_key(fields, "nkey")
      assert_received {:closed, @host}
    end

    test "WH-17: a credential without a user name is sent as the token", ctx do
      server()
      config = anonymous(%{credential: Redacted.wrap("tok-123")})

      assert {:ok, _receipt} = NatsJetstream.deliver(config, prepared(), ctx.options)

      assert_received {:nats, :connect, fields}
      assert fields["auth_token"] == "tok-123"
      refute is_map_key(fields, "user")
      refute is_map_key(fields, "nkey")
    end

    test "WH-17: an NKey seed signs the nonce of the server", ctx do
      server(@host, %{info: Map.put(@info, "nonce", "nonce-4f2a")})
      seed = Nkey.encode_seed(:crypto.strong_rand_bytes(32))
      config = anonymous(%{credential: Redacted.wrap(seed)})

      assert {:ok, _receipt} = NatsJetstream.deliver(config, prepared(), ctx.options)

      assert_received {:nats, :connect, fields}
      assert %{"nkey" => "U" <> _rest = public, "sig" => signature} = fields
      assert {:ok, <<160, k::binary-size(32), _::16>>} = Base.decode32(public, padding: false)
      assert {:ok, signature} = Base.url_decode64(signature, padding: false)
      assert :crypto.verify(:eddsa, :none, "nonce-4f2a", signature, [k, :ed25519])
      refute is_map_key(fields, "auth_token")
      refute Jason.encode!(fields) =~ seed
    end

    test "WH-17: a client certificate reaches the connection and no secret is sent", ctx do
      server()
      certificate = %{certificate: <<1, 2, 3>>, key: Redacted.wrap({:ECPrivateKey, <<4>>})}
      config = anonymous(%{client_certificate: certificate})

      assert {:ok, _receipt} = NatsJetstream.deliver(config, prepared(), ctx.options)

      assert_received {:dialed, %{client_certificate: ^certificate}}
      assert_received {:nats, :connect, fields}
      refute is_map_key(fields, "user")
      refute is_map_key(fields, "auth_token")
      refute is_map_key(fields, "nkey")
    end

    test "WH-17: without credentials nothing but the connection options is sent", ctx do
      server()

      assert {:ok, _receipt} = NatsJetstream.deliver(anonymous(), prepared(), ctx.options)

      assert_received {:dialed, %{client_certificate: nil}}
      assert_received {:nats, :connect, fields}
      names = ~w(headers lang name no_responders pedantic protocol tls_required verbose version)
      assert Enum.sort(Map.keys(fields)) == names
    end

    test "WH-17: a server that refuses the credentials gives a credentials failure", ctx do
      server(@host, %{pong: "-ERR 'Authorization Violation'\r\n"})

      assert {:error, %{class: :credentials, reason: "authorization_violation"} = failure} =
               NatsJetstream.deliver(config(), prepared(), ctx.options)

      assert failure.address == "203.0.114.10"

      assert %Outcome{result: :retry, reason: :credentials_unavailable, breaker: :neutral} =
               Outcome.classify({:error, failure}, @now)

      refute_received {:nats, :publish, _subject, _reply, _headers, _payload}
      assert_received {:closed, @host}
    end

    test "WH-17: a subject the user may not publish to gives a credentials failure", ctx do
      denied = ~s(-ERR 'Permissions Violation for Publish to "orders.shipped"'\r\n)
      server(@host, %{ack: fn _inbox -> denied end})

      assert {:error, %{class: :credentials, reason: "permissions_violation"}} =
               NatsJetstream.deliver(config(), prepared(), ctx.options)
    end

    test "WH-17: a server without TLS is not used and nothing is sent to it", ctx do
      server(@host, %{info: %{"server_id" => "NTEST", "tls_required" => false}})

      assert {:error, %{class: :tls, reason: "tls_not_offered"} = failure} =
               NatsJetstream.deliver(config(), prepared(), ctx.options)

      assert %Outcome{result: :retry, reason: :tls_error} =
               Outcome.classify({:error, failure}, @now)

      refute_received {:upgraded, _host}
      refute_received {:nats, :connect, _fields}
      assert_received {:closed, @host}
    end

    test "WH-17: a server that only offers TLS is upgraded as well", ctx do
      server(@host, %{info: %{"server_id" => "NTEST", "tls_available" => true}})

      assert {:ok, _receipt} = NatsJetstream.deliver(config(), prepared(), ctx.options)
      assert_received {:upgraded, @host}
    end

    test "WH-17: a configuration that cannot be used is refused before any connection", ctx do
      server()
      pem = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"

      configs = [
        config(%{subject: "orders..shipped"}),
        config(%{subject: "orders.*"}),
        config(%{subject: "orders shipped\r\nPING"}),
        config(%{subject: String.duplicate("a", 257)}),
        Map.delete(config(), :subject),
        config(%{servers: []}),
        config(%{servers: [@host]}),
        config(%{servers: [@host <> ":4222", "nats://x:4222"]}),
        config(%{cloudevents_mode: "batch"}),
        %{config() | credential: "s3cr3t-pass"},
        Map.delete(config(), :credential),
        config(%{client_certificate: pem}),
        anonymous(%{credential: "tok-123"}),
        anonymous(%{client_certificate: pem, credential: Redacted.wrap("not a key")})
      ]

      for config <- configs do
        assert {:error, %{class: :invalid, address: nil} = failure} =
                 NatsJetstream.deliver(config, prepared(), ctx.options)

        assert %Outcome{result: :dead_lettered, reason: :destination_invalid} =
                 Outcome.classify({:error, failure}, @now)
      end

      refute_received {:dialed, _connection}
    end
  end

  describe "WH-18 publish acknowledgement" do
    test "WH-18: the acknowledgement of the stream is the success", ctx do
      server()

      assert {:ok, receipt} = NatsJetstream.deliver(config(), prepared(), ctx.options)
      assert %{kind: :write, address: "203.0.114.10", duration_ms: duration_ms} = receipt
      assert duration_ms >= 0
      assert map_size(receipt) == 3

      assert %Outcome{result: :delivered, reason: :acknowledged, breaker: :success} =
               Outcome.classify({:ok, receipt}, @now)

      assert_received {:nats, :sub, "_INBOX." <> unique = inbox}
      assert byte_size(unique) == 22
      assert_received {:nats, :publish, "orders.shipped", ^inbox, _headers, _payload}
    end

    test "WH-18: the CloudEvents id is the message id JetStream deduplicates by", ctx do
      server()

      for mode <- ["binary", "structured"] do
        config = config(%{cloudevents_mode: mode})
        assert {:ok, _receipt} = NatsJetstream.deliver(config, prepared(), ctx.options)
        assert_received {:nats, :publish, _subject, _reply, headers, _payload}
        assert {"Nats-Msg-Id", "evt_1"} in headers
      end
    end

    test "WH-18: a refusal of the stream is classified by its code", ctx do
      cases = [
        {refusal(503, 10_077), :unavailable, "nats_error_10077"},
        {refusal(500, 10_023), :unavailable, "nats_error_10023"},
        {refusal(400, 10_071), :rejected, "nats_error_10071"},
        {fn inbox -> msg(inbox, ~s({"error":{"code":404}})) end, :rejected, "nats_error_404"},
        {fn inbox -> msg(inbox, ~s({"error":{}})) end, :rejected, "nats_error"}
      ]

      for {ack, class, reason} <- cases do
        server(@host, %{ack: ack})

        assert {:error, %{class: ^class, reason: ^reason, address: "203.0.114.10"}} =
                 NatsJetstream.deliver(config(), prepared(), ctx.options)
      end
    end

    test "WH-18: a subject no stream listens on is unavailability", ctx do
      server(@host, %{ack: &no_responders/1})

      assert {:error, %{class: :unavailable, reason: "no_responders"} = failure} =
               NatsJetstream.deliver(config(), prepared(), ctx.options)

      assert %Outcome{result: :retry, reason: :destination_unavailable, breaker: :failure} =
               Outcome.classify({:error, failure}, @now)
    end

    test "WH-18: a reply that is not an acknowledgement is a protocol error", ctx do
      for payload <- [~s({"stream":"EVENTS"}), "+OK", ""] do
        server(@host, %{ack: fn inbox -> msg(inbox, payload) end})

        assert {:error, %{class: :protocol, reason: "invalid_acknowledgement"}} =
                 NatsJetstream.deliver(config(), prepared(), ctx.options)
      end
    end

    test "WH-18: a ping of the server is answered while the acknowledgement is awaited", ctx do
      server(@host, %{ack: fn _inbox -> "PING\r\n" end, ponged: &ack/1})

      assert {:ok, _receipt} = NatsJetstream.deliver(config(), prepared(), ctx.options)
      assert_received {:nats, :pong}
    end

    test "WH-18: without an acknowledgement the attempt ends as a timeout", ctx do
      server(@host, %{ack: fn _inbox -> "" end})

      assert {:error, %{class: :timeout} = failure} =
               NatsJetstream.deliver(config(), prepared(), ctx.options)

      assert %Outcome{result: :retry, reason: :timeout} =
               Outcome.classify({:error, failure}, @now)

      assert_received {:closed, @host}
    end

    test "WH-18: a line or a message larger than the caller allows is a protocol error", ctx do
      options = Keyword.put(ctx.options, :max_frame_bytes, 256)
      large = Jason.encode!(%{"stream" => String.duplicate("E", 300), "seq" => 1})
      server(@host, %{ack: fn inbox -> msg(inbox, large) end})

      assert {:error, %{class: :protocol, reason: "invalid_message"}} =
               NatsJetstream.deliver(config(), prepared(), options)

      server(@host, %{info: Map.put(@info, "cluster", String.duplicate("c", 300))})

      assert {:error, %{class: :protocol, reason: "frame_too_large"}} =
               NatsJetstream.deliver(config(), prepared(), options)
    end

    test "WH-18: an error line of the server is a protocol error", ctx do
      server(@host, %{ack: fn _inbox -> "-ERR 'Unknown Protocol Operation'\r\n" end})

      assert {:error, %{class: :protocol, reason: "server_error"}} =
               NatsJetstream.deliver(config(), prepared(), ctx.options)

      server(@host, %{ack: fn _inbox -> "-ERR 'Maximum Payload Violation'\r\n" end})

      assert {:error, %{class: :rejected, reason: "payload_too_large"}} =
               NatsJetstream.deliver(config(), prepared(), ctx.options)
    end
  end

  describe "WH-8 CloudEvents binding" do
    test "WH-8: binary mode carries the attributes as headers and data as the payload", ctx do
      server()
      prepared = prepared()

      assert {:ok, _receipt} = NatsJetstream.deliver(config(), prepared, ctx.options)

      assert_received {:nats, :publish, "orders.shipped", _reply, headers, payload}
      assert {"ce-specversion", "1.0"} in headers
      assert {"ce-id", "evt_1"} in headers
      assert {"ce-type", "order.shipped"} in headers
      assert {"ce-source", "https://shop.example/orders"} in headers
      assert {"ce-subject", "order/o-1"} in headers
      assert {"ce-time", "2026-11-16T08:00:00Z"} in headers
      assert {"ce-datacontenttype", "application/json"} in headers
      refute List.keymember?(headers, "content-type", 0)
      assert payload == prepared.data
      assert payload == ~s({"order_id":"o-1"})
    end

    test "WH-8: structured mode carries the whole event as the payload", ctx do
      server()
      prepared = prepared()
      config = config(%{cloudevents_mode: "structured"})

      assert {:ok, _receipt} = NatsJetstream.deliver(config, prepared, ctx.options)

      assert_received {:nats, :publish, "orders.shipped", _reply, headers, payload}
      assert headers == [{"Nats-Msg-Id", "evt_1"}, {"content-type", Envelope.content_type()}]
      assert payload == prepared.body
    end
  end

  describe "WH-43 egress rules" do
    test "WH-43: a server address in a blocked range is never connected", ctx do
      server()
      Process.put({:dns, @host}, {:ok, [{10, 0, 0, 1}]})

      assert {:error, %{class: :blocked, address: "10.0.0.1"} = failure} =
               NatsJetstream.deliver(config(), prepared(), ctx.options)

      assert %Outcome{result: :dead_lettered, reason: :destination_blocked, endpoint: :warn} =
               Outcome.classify({:error, failure}, @now)

      refute_received {:dialed, _connection}
    end

    test "WH-43: a blocked server ends the attempt, the next one is not tried", ctx do
      server(@other)
      Process.put({:dns, @host}, {:ok, [{169, 254, 169, 254}]})
      config = config(%{servers: [@host <> ":4222", @other <> ":4222"]})

      assert {:error, %{class: :blocked}} = NatsJetstream.deliver(config, prepared(), ctx.options)

      refute_received {:dialed, _connection}
    end

    test "WH-43: a port the installation does not allow is refused", ctx do
      server()

      config = config(%{servers: [@host <> ":4223"]})

      assert {:error, %{class: :invalid, reason: "port_not_allowed"}} =
               NatsJetstream.deliver(config, prepared(), ctx.options)

      refute_received {:dialed, _connection}
    end

    test "WH-43: the next server is tried when one cannot be reached", ctx do
      ScriptedSocket.refuse(@host, %{class: :connect, reason: "econnrefused"})
      server(@other)
      Process.put({:dns, @other}, {:ok, [{203, 0, 114, 20}]})
      config = config(%{servers: [@host <> ":4222", @other <> ":4222"]})

      assert {:ok, %{address: "203.0.114.20"}} =
               NatsJetstream.deliver(config, prepared(), ctx.options)

      assert_received {:dialed, %{host: @host}}
      assert_received {:dialed, %{host: @other, address: {203, 0, 114, 20}}}
      assert_received {:upgraded, @other}
    end

    test "WH-43: the last server that cannot be reached is the connection error", ctx do
      ScriptedSocket.refuse(@host, %{class: :connect, reason: "econnrefused"})

      assert {:error, %{class: :connect, reason: "econnrefused", address: "203.0.114.10"}} =
               NatsJetstream.deliver(config(), prepared(), ctx.options)
    end
  end

  describe "WH-19 credentials" do
    test "WH-19: no secret appears in a failure or in a receipt", ctx do
      server(@host, %{pong: "-ERR 'Authorization Violation'\r\n"})
      seed = Nkey.encode_seed(:crypto.strong_rand_bytes(32))

      secrets = [
        {config(), "s3cr3t-pass"},
        {anonymous(%{credential: Redacted.wrap("tok-123")}), "tok-123"},
        {anonymous(%{credential: Redacted.wrap(seed)}), seed}
      ]

      for {config, secret} <- secrets do
        assert {:error, failure} = NatsJetstream.deliver(config, prepared(), ctx.options)
        refute inspect(failure) =~ secret
        refute inspect(config) =~ secret
      end

      server()
      assert {:ok, receipt} = NatsJetstream.deliver(config(), prepared(), ctx.options)
      refute inspect(receipt) =~ "s3cr3t"
    end
  end
end
