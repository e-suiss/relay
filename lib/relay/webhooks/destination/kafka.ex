defmodule Relay.Webhooks.Destination.Kafka do
  @moduledoc """
  The Kafka destination (WH-17): one record produced to a topic, acknowledged by every in-sync replica of its partition (WH-18).

  One attempt connects to the first bootstrap broker that can be reached, authenticates, asks for the metadata of the topic, chooses the partition and produces to the broker that leads it. Every connection is made through `Relay.Webhooks.Destination.Socket`, the leader's included: the address a broker advertises is validated like a configured one, and a blocked one ends the attempt (WH-43). Every connection is TLS; a plaintext listener is not spoken to. Nothing is kept between attempts.

  The record key is the ordering key of the event, its subject, and the partition is the one the Java client chooses for that key, so the events of one subject stay in one partition, in the order they were produced (WH-20 (3), AG-24). An event without a subject has no key; its partition comes from its id. The CloudEvents `id` is the key a consumer removes duplicates with: delivery is at least once.

  The event is carried in the binary mode of the CloudEvents Kafka binding by default, the attributes as `ce_` headers, `content-type` and `data` as the value, or in structured mode, the whole event as the value (WH-8 (3)).

  Configuration: `:brokers` (`host:port` texts), `:topic`, `:cloudevents_mode` (`"binary"` or `"structured"`), and for authentication `:sasl_mechanism` (`"plain"`, `"scram_sha_256"`, `"scram_sha_512"`) with `:username` and the password as `:credential`, or `:client_certificate`, a PEM chain whose private key is the `:credential`, or the map the egress boundary takes. The password and the key are wrapped values and appear in no failure and in no receipt (WH-19).

  Options: `:policy`, `:connect_timeout_ms`, `:total_timeout_ms`, `:ack_timeout_ms` (how long the broker may wait for its replicas) and `:max_frame_bytes` (the largest response accepted) are required, and so is `:max_scram_iterations` with a SCRAM mechanism; `:dns_timeout_ms`, `:resolver`, `:dialer`, `:ca_certificates`, `:client_id` and `:now` are optional.
  """

  @behaviour Relay.Webhooks.Destination

  alias Relay.Clock
  alias Relay.Random
  alias Relay.Redacted
  alias Relay.Webhooks.Destination.Kafka.Protocol
  alias Relay.Webhooks.Destination.Kafka.Scram
  alias Relay.Webhooks.Destination.Socket
  alias Relay.Webhooks.Envelope

  @socket_options [:connect_timeout_ms, :dns_timeout_ms, :resolver, :dialer, :ca_certificates]
  @client_id "suiss-relay"
  @topic ~r/\A[A-Za-z0-9._-]{1,249}\z/
  @modes ["binary", "structured"]
  @mechanisms %{
    "plain" => {:plain, "PLAIN"},
    "scram_sha_256" => {:sha256, "SCRAM-SHA-256"},
    "scram_sha_512" => {:sha512, "SCRAM-SHA-512"}
  }
  @next [:connect, :timeout, :dns]
  @credentials [29, 31, 58]
  @rejected [10, 17, 18, 21, 33, 35, 87]
  @all_in_sync -1
  @nonce_bytes 24
  @handshake_id 1
  @first_id 2
  @final_id 3
  @metadata_id 4
  @produce_id 5

  # WH-17
  # WH-18
  @impl Relay.Webhooks.Destination
  def deliver(config, prepared, opts) when is_map(config) and is_list(opts) do
    started = Clock.monotonic_ms()

    result =
      with {:ok, plan} <- plan(config, opts),
           {:ok, session} <- bootstrap(plan.brokers, plan) do
        routed(session, plan, prepared)
      end

    timed(result, max(Clock.monotonic_ms() - started, 0))
  end

  defp timed({:ok, address}, ms), do: {:ok, %{kind: :write, duration_ms: ms, address: address}}
  defp timed({:error, error}, ms), do: {:error, Map.put(error, :duration_ms, ms)}

  defp plan(config, opts) do
    with {:ok, brokers} <- brokers(Map.get(config, :brokers)),
         {:ok, topic} <- topic(Map.get(config, :topic)),
         {:ok, mode} <- mode(Map.get(config, :cloudevents_mode, "binary")),
         {:ok, auth} <- auth(config),
         {:ok, certificate} <- certificate(config, auth) do
      target = %{brokers: brokers, topic: topic, mode: mode, auth: auth}
      {:ok, Map.merge(target, settings(auth, certificate, opts))}
    end
  end

  defp settings(auth, certificate, opts) do
    now = Keyword.get_lazy(opts, :now, &Clock.utc_now/0)

    %{
      policy: Keyword.fetch!(opts, :policy),
      socket: Keyword.take(opts, @socket_options) ++ [client_certificate: certificate],
      client_id: Keyword.get(opts, :client_id, @client_id),
      deadline: Socket.deadline(Keyword.fetch!(opts, :total_timeout_ms)),
      ack_timeout_ms: Keyword.fetch!(opts, :ack_timeout_ms),
      max_frame_bytes: Keyword.fetch!(opts, :max_frame_bytes),
      max_iterations: max_iterations(auth, opts),
      timestamp_ms: DateTime.to_unix(now, :millisecond)
    }
  end

  defp max_iterations(%{mechanism: mechanism}, opts) when mechanism != :plain,
    do: Keyword.fetch!(opts, :max_scram_iterations)

  defp max_iterations(_auth, _opts), do: nil

  defp brokers([_first | _rest] = brokers) do
    parsed = Enum.map(brokers, &Socket.endpoint/1)

    if Enum.member?(parsed, :error),
      do: invalid("invalid_brokers"),
      else: {:ok, Enum.map(parsed, &normalised/1)}
  end

  defp brokers(_brokers), do: invalid("invalid_brokers")

  defp normalised({:ok, {host, port}}), do: {String.downcase(host, :ascii), port}

  defp topic(topic) when is_binary(topic) do
    if Regex.match?(@topic, topic), do: {:ok, topic}, else: invalid("invalid_topic")
  end

  defp topic(_topic), do: invalid("invalid_topic")

  defp mode(mode) when mode in @modes, do: {:ok, mode}
  defp mode(_mode), do: invalid("invalid_cloudevents_mode")

  # WH-17
  defp auth(config) do
    case Map.get(config, :sasl_mechanism) do
      nil -> {:ok, nil}
      name when is_map_key(@mechanisms, name) -> sasl(Map.fetch!(@mechanisms, name), config)
      _other -> invalid("invalid_sasl_mechanism")
    end
  end

  defp sasl({mechanism, name}, %{username: username, credential: credential})
       when is_binary(username) and username != "" do
    if password?(credential),
      do: {:ok, %{mechanism: mechanism, name: name, username: username, password: credential}},
      else: invalid("invalid_sasl_credential")
  end

  defp sasl(_mechanism, _config), do: invalid("invalid_sasl_credential")

  defp password?(credential),
    do: Redacted.redacted?(credential) and is_binary(Redacted.expose(credential))

  # WH-17
  defp certificate(config, auth) do
    credential = if auth == nil, do: Map.get(config, :credential)

    case Socket.client_certificate(Map.get(config, :client_certificate), credential) do
      {:ok, certificate} -> {:ok, certificate}
      :error -> invalid("invalid_client_certificate")
    end
  end

  defp bootstrap([endpoint | rest], plan) do
    case session(endpoint, plan) do
      {:ok, socket} -> {:ok, {socket, endpoint}}
      {:error, %{class: class}} when class in @next and rest != [] -> bootstrap(rest, plan)
      {:error, error} -> {:error, error}
    end
  end

  # WH-43
  defp session(endpoint, plan) do
    with {:ok, socket} <- Socket.connect(plan.policy, endpoint, plan.socket) do
      case authenticate(socket, plan) do
        :ok -> {:ok, socket}
        {:error, error} -> closed(socket, {:error, error})
      end
    end
  end

  defp closed(socket, result) do
    :ok = Socket.close(socket)
    result
  end

  defp routed({socket, endpoint}, plan, prepared) do
    case leader(socket, plan, prepared) do
      {:ok, %{endpoint: ^endpoint, partition: partition}} ->
        closed(socket, produce(socket, partition, plan, prepared))

      {:ok, target} ->
        :ok = Socket.close(socket)
        elsewhere(target, plan, prepared)

      {:error, error} ->
        closed(socket, {:error, error})
    end
  end

  # WH-43
  defp elsewhere(%{endpoint: endpoint, partition: partition}, plan, prepared) do
    with {:ok, socket} <- session(endpoint, plan) do
      closed(socket, produce(socket, partition, plan, prepared))
    end
  end

  # WH-20 (3)
  # AG-24
  defp leader(socket, plan, prepared) do
    request = Protocol.metadata(@metadata_id, plan.client_id, plan.topic)

    with {:ok, body} <- call(socket, request, @metadata_id, plan),
         {:ok, metadata} <- decoded(Protocol.decode_metadata(body), socket),
         {:ok, partitions} <- partitions(metadata, plan.topic, socket),
         {:ok, chosen} <- chosen(partitions, hash_key(prepared), socket) do
      advertised(metadata.brokers, chosen, socket)
    end
  end

  defp partitions(metadata, topic, socket) do
    case Enum.find(metadata.topics, &(&1.name == topic)) do
      %{error_code: 0, partitions: [_first | _rest] = partitions} -> {:ok, partitions}
      %{error_code: code} when code != 0 -> refused(code, socket)
      _missing -> failure(:unavailable, "kafka_topic_unknown", socket)
    end
  end

  defp chosen(partitions, key, socket) do
    index = Protocol.partition(key, length(partitions))

    case Enum.find(partitions, &(&1.index == index)) do
      %{leader: leader} when leader >= 0 -> {:ok, {index, leader}}
      %{error_code: code} when code != 0 -> refused(code, socket)
      _missing -> failure(:unavailable, "kafka_leader_unknown", socket)
    end
  end

  defp hash_key(%{partition_key: key}) when is_binary(key), do: key
  defp hash_key(%{id: id}), do: id

  defp advertised(brokers, {index, node}, socket) do
    case Map.get(brokers, node) do
      {host, port} when port >= 1 and port <= 65_535 ->
        {:ok, %{partition: index, endpoint: {String.downcase(host, :ascii), port}}}

      nil ->
        failure(:unavailable, "kafka_leader_unknown", socket)

      _unusable ->
        failure(:protocol, "kafka_broker_address", socket)
    end
  end

  # WH-18
  defp produce(socket, partition, plan, prepared) do
    %{client_id: client_id, topic: topic, ack_timeout_ms: timeout_ms} = plan
    record = record(prepared, plan)

    request =
      Protocol.produce(@produce_id, client_id, topic, partition, record, @all_in_sync, timeout_ms)

    with {:ok, body} <- call(socket, request, @produce_id, plan),
         {:ok, answers} <- decoded(Protocol.decode_produce(body), socket) do
      answers
      |> Enum.find(&(&1.topic == topic and &1.partition == partition))
      |> acknowledged(socket)
    end
  end

  # WH-18
  defp acknowledged(%{error_code: 0}, socket), do: {:ok, Socket.address(socket)}
  defp acknowledged(%{error_code: code}, socket), do: refused(code, socket)
  defp acknowledged(nil, socket), do: failure(:protocol, "kafka_response", socket)

  defp record(prepared, plan) do
    {value, headers} = content(plan.mode, prepared)

    %{
      key: prepared.partition_key,
      value: value,
      headers: headers,
      timestamp_ms: plan.timestamp_ms
    }
  end

  # WH-8 (3)
  defp content("structured", prepared),
    do: {prepared.body, [{"content-type", prepared.content_type}, {"ce_id", prepared.id}]}

  defp content("binary", prepared) do
    default = {"datacontenttype", "application/json"}
    {_name, type} = List.keyfind(prepared.attributes, "datacontenttype", 0, default)
    headers = Envelope.binary_headers(prepared.attributes, :kafka)
    {prepared.data, headers ++ [{"content-type", type}]}
  end

  # WH-17
  defp authenticate(_socket, %{auth: nil}), do: :ok

  defp authenticate(socket, %{auth: auth} = plan) do
    request = Protocol.sasl_handshake(@handshake_id, plan.client_id, auth.name)

    with {:ok, body} <- call(socket, request, @handshake_id, plan),
         :ok <- offered(Protocol.decode_sasl_handshake(body), socket) do
      exchange(auth, socket, plan)
    end
  end

  defp offered({:ok, 0, _mechanisms}, _socket), do: :ok
  defp offered({:ok, code, _mechanisms}, socket), do: refused(code, socket)
  defp offered(:error, socket), do: failure(:protocol, "kafka_response", socket)

  # WH-19
  defp exchange(%{mechanism: :plain} = auth, socket, plan) do
    message = <<0, auth.username::binary, 0, Redacted.expose(auth.password)::binary>>
    with {:ok, _answer} <- step(socket, message, @first_id, plan), do: :ok
  end

  defp exchange(auth, socket, plan) do
    nonce = Base.encode64(Random.bytes(@nonce_bytes))
    {first, bare} = Scram.client_first(auth.username, nonce)

    with {:ok, challenge} <- step(socket, first, @first_id, plan),
         {:ok, final, signature} <- proof(auth, bare, challenge, nonce, plan, socket),
         {:ok, answer} <- step(socket, final, @final_id, plan) do
      trusted(Scram.verify(answer, signature), socket)
    end
  end

  defp proof(auth, bare, challenge, nonce, plan, socket) do
    %{mechanism: hash, password: password} = auth
    secret = Redacted.expose(password)

    case Scram.client_final(hash, secret, bare, challenge, nonce, plan.max_iterations) do
      {:ok, final, signature} -> {:ok, final, signature}
      :error -> failure(:protocol, "kafka_scram_challenge", socket)
    end
  end

  defp trusted(:ok, _socket), do: :ok
  defp trusted(:error, socket), do: failure(:credentials, "kafka_scram_server", socket)

  defp step(socket, message, id, plan) do
    request = Protocol.sasl_authenticate(id, plan.client_id, message)

    with {:ok, body} <- call(socket, request, id, plan) do
      authenticated(Protocol.decode_sasl_authenticate(body), socket)
    end
  end

  defp authenticated({:ok, 0, message}, _socket), do: {:ok, message}

  defp authenticated({:ok, code, _message}, socket),
    do: failure(:credentials, "kafka_error_" <> Integer.to_string(code), socket)

  defp authenticated(:error, socket), do: failure(:protocol, "kafka_response", socket)

  # WH-24
  defp call(socket, request, correlation, plan) do
    with :ok <- Socket.write(socket, request),
         {:ok, head} <- Socket.read(socket, 4, plan.deadline),
         {:ok, size} <- size(head, plan.max_frame_bytes, socket),
         {:ok, frame} <- Socket.read(socket, size, plan.deadline) do
      decoded(Protocol.response(frame, correlation), socket)
    end
  end

  defp size(<<size::32>>, max, _socket) when size >= 4 and size <= max, do: {:ok, size}
  defp size(_head, _max, socket), do: failure(:protocol, "kafka_frame_size", socket)

  defp decoded({:ok, value}, _socket), do: {:ok, value}
  defp decoded(:error, socket), do: failure(:protocol, "kafka_response", socket)

  defp refused(code, socket) do
    class =
      cond do
        code in @credentials -> :credentials
        code in @rejected -> :rejected
        true -> :unavailable
      end

    failure(class, "kafka_error_" <> Integer.to_string(code), socket)
  end

  defp failure(class, reason, socket),
    do: {:error, %{class: class, reason: reason, address: Socket.address(socket)}}

  defp invalid(reason), do: {:error, %{class: :invalid, reason: reason, address: nil}}
end
