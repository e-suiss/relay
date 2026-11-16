defmodule Relay.Webhooks.Destination.KafkaTest.FakeResolver do
  @behaviour Relay.Webhooks.Egress.Resolver

  @impl Relay.Webhooks.Egress.Resolver
  def resolve(host, _timeout_ms), do: Process.get({:dns, host}, {:ok, [{203, 0, 114, 10}]})
end

defmodule Relay.Webhooks.Destination.KafkaTest.Broker do
  import Bitwise

  alias RelayTest.ScriptedSocket

  @defaults %{
    partitions: 3,
    nodes: nil,
    leader: 1,
    topic_error: 0,
    produce_error: 0,
    handshake_error: 0,
    plain: nil,
    scram: nil,
    garbage: false
  }

  def start(host, overrides \\ %{}) do
    state = @defaults |> Map.merge(overrides) |> Map.put(:host, host)
    ScriptedSocket.serve(host, &handle/2, state)
  end

  def scram(hash, password, overrides \\ %{}) do
    scram = %{hash: hash, password: password, salt: "0123456789abcdef", iterations: 4096}
    Map.merge(Map.merge(scram, %{step: 1, forge: false}), overrides)
  end

  def handle({:data, _frame}, %{garbage: true} = state),
    do: {<<0, 0, 0, 6, 0, 0, 0, 9, 1, 2>>, state}

  def handle({:data, <<size::32, request::binary-size(size)>>}, state) do
    <<api::16, version::16, correlation::32, rest::binary>> = request
    <<length::16, client::binary-size(length), body::binary>> = rest
    send(self(), {:kafka, state.host, api, version, client})
    {answer, state} = answer(api, body, state)
    payload = IO.iodata_to_binary([<<correlation::32>>, answer])
    {[<<byte_size(payload)::32>>, payload], state}
  end

  def handle(_event, state), do: {"", state}

  defp answer(17, <<length::16, mechanism::binary-size(length)>>, state) do
    send(self(), {:mechanism, state.host, mechanism})
    {[<<state.handshake_error::16, 1::32>>, string(mechanism)], state}
  end

  defp answer(36, <<length::32, message::binary-size(length)>>, state) do
    {code, reply, state} = sasl(message, state)
    {[<<code::16, -1::16-signed, byte_size(reply)::32>>, reply], state}
  end

  defp answer(3, <<1::32, length::16, topic::binary-size(length), 0>>, state) do
    nodes = state.nodes || %{1 => {state.host, 9093}}
    brokers = for {id, address} <- nodes, do: broker(id, address)
    partitions = for index <- 0..(state.partitions - 1)//1, do: partition(index, state.leader)
    head = [<<0::32, map_size(nodes)::32>>, brokers, <<-1::16-signed, 1::32, 1::32>>]
    named = [<<state.topic_error::16>>, string(topic), <<0, state.partitions::32>>]
    {[head, named, partitions], state}
  end

  defp answer(0, <<-1::16-signed, acks::16-signed, timeout::32, 1::32, rest::binary>>, state) do
    <<length::16, topic::binary-size(length), 1::32, partition::32, rest::binary>> = rest
    <<size::32, batch::binary-size(size)>> = rest
    produced = %{acks: acks, timeout_ms: timeout, topic: topic, partition: partition}
    send(self(), {:produced, state.host, Map.merge(produced, batch(batch))})
    tail = <<1::32, partition::32, state.produce_error::16, 42::64, -1::64-signed, 0::32>>
    {[<<1::32>>, string(topic), tail], state}
  end

  defp broker(id, {host, port}), do: [<<id::32>>, string(host), <<port::32, -1::16-signed>>]

  defp partition(index, leader) do
    replicas = <<1::32, leader::32-signed>>
    [<<0::16, index::32, leader::32-signed>>, replicas, replicas]
  end

  defp string(text), do: [<<byte_size(text)::16>>, text]

  defp batch(<<0::64, length::32, -1::32-signed, 2, crc::32, checked::binary>> = batch) do
    <<0::16, 0::32, first::64, last::64, -1::64-signed, rest::binary>> = checked
    <<-1::16-signed, -1::32-signed, 1::32, records::binary>> = rest
    {size, record} = varint(records)
    sizes = %{batch_length: length, after_length: byte_size(batch) - 12}
    framing = %{crc: crc, checked: checked, timestamps: {first, last}, record_size: size}
    Map.merge(Map.merge(sizes, framing), record(record))
  end

  defp record(<<0, rest::binary>> = record) do
    {0, rest} = varint(rest)
    {0, rest} = varint(rest)
    {key, rest} = sized(rest)
    {value, rest} = sized(rest)
    {count, rest} = varint(rest)
    %{key: key, value: value, headers: headers(count, rest), record_bytes: byte_size(record)}
  end

  defp headers(0, ""), do: []

  defp headers(count, binary) do
    {name, rest} = sized(binary)
    {value, rest} = sized(rest)
    [{name, value} | headers(count - 1, rest)]
  end

  defp sized(binary) do
    case varint(binary) do
      {length, rest} when length < 0 ->
        {nil, rest}

      {length, rest} ->
        {binary_part(rest, 0, length), binary_part(rest, length, byte_size(rest) - length)}
    end
  end

  defp varint(binary), do: varint(binary, 0, 0)

  defp varint(<<1::1, bits::7, rest::binary>>, shift, sum),
    do: varint(rest, shift + 7, sum + (bits <<< shift))

  defp varint(<<0::1, bits::7, rest::binary>>, shift, sum) do
    raw = sum + (bits <<< shift)
    {bxor(raw >>> 1, -band(raw, 1)), rest}
  end

  defp sasl(message, %{scram: nil} = state) do
    send(self(), {:sasl, state.host, message})
    code = if state.plain in [nil, message], do: 0, else: 58
    {code, "", state}
  end

  defp sasl("n,," <> bare, %{scram: %{step: 1} = scram} = state) do
    [_user, "r=" <> nonce] = String.split(bare, ",")
    count = Integer.to_string(scram.iterations)
    first = "r=" <> nonce <> "srv,s=" <> Base.encode64(scram.salt) <> ",i=" <> count
    {0, first, %{state | scram: Map.merge(scram, %{step: 2, bare: bare, first: first})}}
  end

  defp sasl(final, %{scram: %{step: 2} = scram} = state) do
    [unproved, proof] = String.split(final, ",p=")
    message = scram.bare <> "," <> scram.first <> "," <> unproved
    {code, reply} = verdict(scram, message, Base.decode64!(proof))
    {code, reply, state}
  end

  defp verdict(%{hash: hash} = scram, message, proof) do
    size = byte_size(:crypto.hash(hash, ""))
    salted = :crypto.pbkdf2_hmac(hash, scram.password, scram.salt, scram.iterations, size)
    stored = :crypto.hash(hash, :crypto.mac(:hmac, hash, salted, "Client Key"))
    client_key = :crypto.exor(proof, :crypto.mac(:hmac, hash, stored, message))
    server_key = :crypto.mac(:hmac, hash, salted, "Server Key")
    signature = if scram.forge, do: stored, else: :crypto.mac(:hmac, hash, server_key, message)

    if :crypto.hash(hash, client_key) == stored,
      do: {0, "v=" <> Base.encode64(signature)},
      else: {58, ""}
  end
end

defmodule Relay.Webhooks.Destination.KafkaTest do
  use ExUnit.Case, async: true

  alias Relay.Redacted
  alias Relay.Webhooks.Destination
  alias Relay.Webhooks.Destination.Kafka
  alias Relay.Webhooks.Destination.Kafka.Protocol
  alias Relay.Webhooks.Destination.KafkaTest.Broker
  alias Relay.Webhooks.Destination.KafkaTest.FakeResolver
  alias Relay.Webhooks.Egress.Policy
  alias Relay.Webhooks.Envelope
  alias Relay.Webhooks.Outcome
  alias RelayTest.ScriptedSocket

  @now ~U[2026-11-16 08:00:00Z]
  @host "kafka.example.com"
  @other "kafka-2.example.com"
  @config %{brokers: ["kafka.example.com:9093"], topic: "orders.v1"}

  setup do
    {:ok, policy} = Policy.new(deployment: :saas, extra_ports: [9093])

    options = [
      policy: policy,
      connect_timeout_ms: 5_000,
      total_timeout_ms: 20_000,
      ack_timeout_ms: 30_000,
      max_frame_bytes: 65_536,
      max_scram_iterations: 10_000,
      resolver: FakeResolver,
      dialer: ScriptedSocket,
      now: @now
    ]

    %{options: options}
  end

  defp prepared(overrides \\ %{}) do
    fields = %{
      id: "evt_1",
      source: "https://shop.example/orders",
      type: "order.shipped",
      time: @now,
      subject: "order/o-1",
      data: %{"order_id" => "o-1"}
    }

    {:ok, envelope} = Envelope.new(:destination, Map.merge(fields, overrides))
    Destination.prepare(envelope, Envelope.encode(envelope), [], 1)
  end

  defp sasl(mechanism, password) do
    credential = Redacted.wrap(password)
    Map.merge(@config, %{sasl_mechanism: mechanism, username: "relay", credential: credential})
  end

  defp requests(host) do
    receive do
      {:kafka, ^host, api, version, _client} -> [{api, version} | requests(host)]
    after
      0 -> []
    end
  end

  describe "WH-18 durable write acknowledgement" do
    test "WH-18: a record acknowledged by every in-sync replica is delivered", ctx do
      Broker.start(@host)

      assert {:ok, receipt} = Kafka.deliver(@config, prepared(), ctx.options)
      assert %{kind: :write, address: "203.0.114.10", duration_ms: duration_ms} = receipt
      assert duration_ms >= 0
      outcome = Outcome.classify({:ok, receipt}, @now)
      assert %Outcome{result: :delivered, breaker: :success} = outcome

      assert_received {:dialed, %{host: @host, port: 9093, mode: :tls} = connection}
      assert connection.address == {203, 0, 114, 10}
      refute_received {:dialed, _connection}
      assert requests(@host) == [{3, 4}, {0, 3}]

      assert_received {:produced, @host, produced}
      assert %{acks: -1, timeout_ms: 30_000, topic: "orders.v1"} = produced
      assert_received {:closed, @host}
    end

    test "WH-18: the record batch is format v2 with a valid CRC-32C and its lengths", ctx do
      Broker.start(@host)

      assert {:ok, _receipt} = Kafka.deliver(@config, prepared(), ctx.options)
      assert_received {:produced, @host, produced}

      assert produced.crc == Protocol.crc32c(produced.checked)
      assert produced.batch_length == produced.after_length
      assert produced.record_size == produced.record_bytes
      milliseconds = DateTime.to_unix(@now, :millisecond)
      assert produced.timestamps == {milliseconds, milliseconds}
    end

    test "WH-18: a broker that does not acknowledge now is retried", ctx do
      Broker.start(@host, %{produce_error: 19})

      assert {:error, failure} = Kafka.deliver(@config, prepared(), ctx.options)
      assert %{class: :unavailable, reason: "kafka_error_19", address: "203.0.114.10"} = failure
      assert %Outcome{result: :retry} = Outcome.classify({:error, failure}, @now)
      assert_received {:closed, @host}
    end

    test "WH-18: a record the broker refuses for good is dead-lettered", ctx do
      Broker.start(@host, %{produce_error: 10})

      assert {:error, %{class: :rejected, reason: "kafka_error_10"} = failure} =
               Kafka.deliver(@config, prepared(), ctx.options)

      assert %Outcome{result: :dead_lettered} = Outcome.classify({:error, failure}, @now)
    end

    test "WH-18: a topic the broker does not know is not available", ctx do
      Broker.start(@host, %{topic_error: 3})

      assert {:error, %{class: :unavailable, reason: "kafka_error_3"}} =
               Kafka.deliver(@config, prepared(), ctx.options)

      refute_received {:produced, _host, _produced}
    end

    test "WH-18: a topic the credentials may not write to is a credentials failure", ctx do
      Broker.start(@host, %{produce_error: 29})

      assert {:error, %{class: :credentials, reason: "kafka_error_29"}} =
               Kafka.deliver(@config, prepared(), ctx.options)
    end

    test "WH-18: an unreadable or oversized response is a protocol error", ctx do
      Broker.start(@host, %{garbage: true})

      assert {:error, %{class: :protocol, reason: "kafka_response"} = failure} =
               Kafka.deliver(@config, prepared(), ctx.options)

      assert %Outcome{result: :retry} = Outcome.classify({:error, failure}, @now)

      Broker.start(@host)
      options = Keyword.put(ctx.options, :max_frame_bytes, 8)

      assert {:error, %{class: :protocol, reason: "kafka_frame_size"}} =
               Kafka.deliver(@config, prepared(), options)
    end

    test "WH-18: the next bootstrap broker is tried when one cannot be reached", ctx do
      ScriptedSocket.refuse(@host, %{class: :connect, reason: "econnrefused"})
      Broker.start(@other, %{nodes: %{7 => {@other, 9093}}, leader: 7})
      config = %{@config | brokers: ["kafka.example.com:9093", "kafka-2.example.com:9093"]}

      assert {:ok, %{kind: :write}} = Kafka.deliver(config, prepared(), ctx.options)
      assert_received {:produced, @other, _produced}
    end
  end

  describe "WH-8 CloudEvents binding" do
    test "WH-8: binary mode carries the attributes as headers and data as the value", ctx do
      Broker.start(@host)
      prepared = prepared()

      assert {:ok, _receipt} = Kafka.deliver(@config, prepared, ctx.options)
      assert_received {:produced, @host, %{value: value, headers: headers}}

      assert value == ~s({"order_id":"o-1"})
      assert {"ce_specversion", "1.0"} in headers
      assert {"ce_id", "evt_1"} in headers
      assert {"ce_type", "order.shipped"} in headers
      assert {"ce_source", "https://shop.example/orders"} in headers
      assert {"ce_subject", "order/o-1"} in headers
      assert {"content-type", "application/json"} in headers
      refute List.keymember?(headers, "ce_datacontenttype", 0)
    end

    test "WH-8: structured mode carries the whole event as the value", ctx do
      Broker.start(@host)
      prepared = prepared()
      config = Map.put(@config, :cloudevents_mode, "structured")

      assert {:ok, _receipt} = Kafka.deliver(config, prepared, ctx.options)
      assert_received {:produced, @host, %{value: value, headers: headers}}

      assert value == prepared.body
      assert Jason.decode!(value)["id"] == "evt_1"

      assert headers == [
               {"content-type", "application/cloudevents+json; charset=utf-8"},
               {"ce_id", "evt_1"}
             ]
    end
  end

  describe "WH-20 ordering key" do
    test "WH-20, AG-24: the subject is the record key and chooses the partition", ctx do
      Broker.start(@host)

      assert {:ok, _receipt} = Kafka.deliver(@config, prepared(), ctx.options)
      assert_received {:produced, @host, %{key: "order/o-1", partition: 0}}

      later = prepared(%{id: "evt_2", data: %{"order_id" => "o-1", "step" => 2}})
      assert {:ok, _receipt} = Kafka.deliver(@config, later, ctx.options)
      assert_received {:produced, @host, %{key: "order/o-1", partition: 0}}

      other = prepared(%{id: "evt_3", subject: "order/o-2"})
      assert {:ok, _receipt} = Kafka.deliver(@config, other, ctx.options)
      assert_received {:produced, @host, %{key: "order/o-2", partition: 1}}
    end

    test "WH-20: an event without a subject has no key and a partition from its id", ctx do
      Broker.start(@host)

      assert {:ok, _receipt} = Kafka.deliver(@config, prepared(%{subject: nil}), ctx.options)
      assert_received {:produced, @host, %{key: nil, partition: 1}}
    end

    test "WH-20: a partition without a leader is not available", ctx do
      Broker.start(@host, %{leader: -1})

      assert {:error, %{class: :unavailable, reason: "kafka_leader_unknown"}} =
               Kafka.deliver(@config, prepared(), ctx.options)

      refute_received {:produced, _host, _produced}
    end
  end

  describe "WH-17 authentication" do
    test "WH-17: SASL PLAIN sends the user name and the password before anything else", ctx do
      Broker.start(@host, %{plain: <<0, "relay", 0, "s3cr3t-plain">>})

      config = sasl("plain", "s3cr3t-plain")

      assert {:ok, _receipt} = Kafka.deliver(config, prepared(), ctx.options)
      assert requests(@host) == [{17, 1}, {36, 0}, {3, 4}, {0, 3}]
      assert_received {:mechanism, @host, "PLAIN"}
    end

    test "WH-17, WH-19: a refused password is a credentials failure without the password", ctx do
      Broker.start(@host, %{plain: <<0, "relay", 0, "another">>})

      assert {:error, failure} =
               Kafka.deliver(sasl("plain", "s3cr3t-plain"), prepared(), ctx.options)

      assert %{class: :credentials, reason: "kafka_error_58"} = failure
      refute inspect(failure) =~ "s3cr3t-plain"
      outcome = Outcome.classify({:error, failure}, @now)
      assert %Outcome{result: :retry, breaker: :neutral} = outcome
      assert requests(@host) == [{17, 1}, {36, 0}]
      assert_received {:closed, @host}
    end

    test "WH-17: SCRAM-SHA-256 proves the password and checks the server's proof", ctx do
      Broker.start(@host, %{scram: Broker.scram(:sha256, "pencil")})

      config = sasl("scram_sha_256", "pencil")

      assert {:ok, _receipt} = Kafka.deliver(config, prepared(), ctx.options)
      assert requests(@host) == [{17, 1}, {36, 0}, {36, 0}, {3, 4}, {0, 3}]
      assert_received {:mechanism, @host, "SCRAM-SHA-256"}
    end

    test "WH-17: SCRAM-SHA-512 proves the password and checks the server's proof", ctx do
      Broker.start(@host, %{scram: Broker.scram(:sha512, "pencil")})

      config = sasl("scram_sha_512", "pencil")

      assert {:ok, _receipt} = Kafka.deliver(config, prepared(), ctx.options)
      assert_received {:mechanism, @host, "SCRAM-SHA-512"}
      assert_received {:produced, @host, _produced}
    end

    test "WH-17, WH-19: a wrong SCRAM password is a credentials failure", ctx do
      Broker.start(@host, %{scram: Broker.scram(:sha256, "pencil")})

      assert {:error, failure} =
               Kafka.deliver(sasl("scram_sha_256", "s3cr3t-scram"), prepared(), ctx.options)

      assert %{class: :credentials, reason: "kafka_error_58"} = failure
      refute inspect(failure) =~ "s3cr3t-scram"
      refute_received {:produced, _host, _produced}
    end

    test "WH-17: a server that cannot prove it knows the password is not trusted", ctx do
      Broker.start(@host, %{scram: Broker.scram(:sha256, "pencil", %{forge: true})})

      assert {:error, %{class: :credentials, reason: "kafka_scram_server"}} =
               Kafka.deliver(sasl("scram_sha_256", "pencil"), prepared(), ctx.options)

      refute_received {:produced, _host, _produced}
    end

    test "WH-17: a SCRAM iteration count above the caller's bound is refused", ctx do
      Broker.start(@host, %{scram: Broker.scram(:sha256, "pencil")})
      options = Keyword.put(ctx.options, :max_scram_iterations, 1_000)

      assert {:error, %{class: :protocol, reason: "kafka_scram_challenge"}} =
               Kafka.deliver(sasl("scram_sha_256", "pencil"), prepared(), options)
    end

    test "WH-17: a mechanism the broker does not have is a rejection", ctx do
      Broker.start(@host, %{handshake_error: 33})

      assert {:error, %{class: :rejected, reason: "kafka_error_33"}} =
               Kafka.deliver(sasl("plain", "s3cr3t-plain"), prepared(), ctx.options)
    end

    test "WH-17: the client certificate reaches every connection", ctx do
      Broker.start(@host)
      certificate = %{certificate: <<1, 2, 3>>, key: Redacted.wrap({:ECPrivateKey, <<4>>})}
      config = Map.put(@config, :client_certificate, certificate)

      assert {:ok, _receipt} = Kafka.deliver(config, prepared(), ctx.options)
      assert_received {:dialed, %{client_certificate: ^certificate}}
      assert requests(@host) == [{3, 4}, {0, 3}]
    end

    test "WH-17: a configuration that cannot be used is invalid and nothing is connected", ctx do
      Broker.start(@host)

      invalid = [
        {%{@config | brokers: []}, "invalid_brokers"},
        {%{@config | brokers: ["kafka.example.com"]}, "invalid_brokers"},
        {%{@config | topic: "orders v1"}, "invalid_topic"},
        {Map.put(@config, :cloudevents_mode, "batch"), "invalid_cloudevents_mode"},
        {Map.put(@config, :sasl_mechanism, "gssapi"), "invalid_sasl_mechanism"},
        {Map.put(@config, :sasl_mechanism, "plain"), "invalid_sasl_credential"},
        {Map.put(sasl("plain", "pw"), :username, ""), "invalid_sasl_credential"},
        {Map.put(@config, :client_certificate, "not a pem"), "invalid_client_certificate"}
      ]

      for {config, reason} <- invalid do
        assert {:error, %{class: :invalid, reason: ^reason, address: nil} = failure} =
                 Kafka.deliver(config, prepared(), ctx.options)

        assert %Outcome{result: :dead_lettered} = Outcome.classify({:error, failure}, @now)
      end

      refute_received {:dialed, _connection}
    end
  end

  describe "WH-43 egress rules" do
    test "WH-43: a bootstrap broker that resolves to a blocked address is never dialed", ctx do
      Broker.start(@host)
      Process.put({:dns, @host}, {:ok, [{203, 0, 114, 10}, {10, 0, 0, 5}]})

      assert {:error, failure} = Kafka.deliver(@config, prepared(), ctx.options)
      assert %{class: :blocked, address: "10.0.0.5"} = failure
      assert %Outcome{result: :dead_lettered, reason: :destination_blocked} =
               Outcome.classify({:error, failure}, @now)

      refute_received {:dialed, _connection}
    end

    test "WH-43: a blocked bootstrap broker ends the attempt, the next one is not tried", ctx do
      Broker.start(@other)
      config = %{@config | brokers: ["169.254.169.254:9093", "kafka-2.example.com:9093"]}

      assert {:error, %{class: :blocked}} = Kafka.deliver(config, prepared(), ctx.options)
      refute_received {:dialed, _connection}
    end

    test "WH-43: a port the installation does not allow is refused", ctx do
      Broker.start(@host)
      config = %{@config | brokers: ["kafka.example.com:9092"]}

      assert {:error, %{class: :invalid, reason: "port_not_allowed"}} =
               Kafka.deliver(config, prepared(), ctx.options)

      refute_received {:dialed, _connection}
    end

    test "WH-43: an advertised leader that resolves to a blocked address is never dialed", ctx do
      Broker.start(@host, %{nodes: %{4 => {"internal.example.com", 9093}}, leader: 4})
      Broker.start("internal.example.com")
      Process.put({:dns, "internal.example.com"}, {:ok, [{10, 0, 0, 9}]})

      assert {:error, failure} = Kafka.deliver(@config, prepared(), ctx.options)
      assert %{class: :blocked, address: "10.0.0.9"} = failure

      assert_received {:dialed, %{host: @host}}
      refute_received {:dialed, _connection}
      refute_received {:produced, _host, _produced}
      assert_received {:closed, @host}
    end

    test "WH-43: an advertised metadata address is never dialed", ctx do
      Broker.start(@host, %{nodes: %{4 => {"169.254.169.254", 9093}}, leader: 4})

      assert {:error, %{class: :blocked}} = Kafka.deliver(@config, prepared(), ctx.options)
      assert_received {:dialed, %{host: @host}}
      refute_received {:dialed, _connection}
    end

    test "WH-43: an advertised leader is validated, dialed and authenticated again", ctx do
      plain = <<0, "relay", 0, "s3cr3t-plain">>
      Broker.start(@host, %{nodes: %{1 => {@host, 9093}, 2 => {@other, 9093}}, leader: 2})
      Broker.start(@other, %{plain: plain})
      Process.put({:dns, @other}, {:ok, [{198, 51, 101, 7}]})

      assert {:ok, %{address: "198.51.101.7"}} =
               Kafka.deliver(sasl("plain", "s3cr3t-plain"), prepared(), ctx.options)

      assert_received {:dialed, %{host: @host}}
      assert_received {:dialed, %{host: @other, address: {198, 51, 101, 7}}}
      assert requests(@host) == [{17, 1}, {36, 0}, {3, 4}]
      assert requests(@other) == [{17, 1}, {36, 0}, {0, 3}]
      assert_received {:sasl, @other, ^plain}
      assert_received {:produced, @other, _produced}
      assert_received {:closed, @host}
      assert_received {:closed, @other}
    end
  end
end
