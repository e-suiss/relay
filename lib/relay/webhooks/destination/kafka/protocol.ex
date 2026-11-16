defmodule Relay.Webhooks.Destination.Kafka.Protocol do
  @moduledoc """
  The part of the Kafka wire protocol one produce needs (WH-17, WH-18), pure: nothing here opens a connection. Requests carry request header v1 and are returned with their four byte size prefix; responses are read from the frame without that prefix.

  | API | Key | Version |
  |---|---|---|
  | Produce | 0 | 3 |
  | Metadata | 3 | 4 |
  | SaslHandshake | 17 | 1 |
  | SaslAuthenticate | 36 | 0 |

  A produce request carries one record batch of format v2 with one record: zigzag varints, a CRC-32C over the batch from its attributes on, no compression and no idempotent producer state. `partition/2` is the partitioner of the Java client for a keyed record, `toPositive(murmur2(key)) mod partitions`, so that a key lands in the partition other producers of the topic choose for it (WH-20 (3)).

  A decoder returns `:error` for a body it cannot read; it never raises.
  """

  import Bitwise

  @produce 0
  @metadata 3
  @sasl_handshake 17
  @sasl_authenticate 36

  @mask 0xFFFFFFFF
  @murmur_seed 0x9747B28C
  @murmur_m 0x5BD1E995

  crc_entry = fn index ->
    Enum.reduce(1..8, index, fn _bit, crc ->
      if band(crc, 1) == 1, do: bxor(crc >>> 1, 0x82F63B78), else: crc >>> 1
    end)
  end

  @crc_table List.to_tuple(Enum.map(0..255, crc_entry))

  @type header :: {String.t(), binary()}
  @type entry :: %{
          key: binary() | nil,
          value: binary(),
          headers: [header()],
          timestamp_ms: non_neg_integer()
        }
  @type broker :: {host :: String.t(), port :: integer()}
  @type partition :: %{error_code: integer(), index: integer(), leader: integer()}
  @type topic :: %{error_code: integer(), name: String.t(), partitions: [partition()]}
  @type metadata :: %{brokers: %{optional(integer()) => broker()}, topics: [topic()]}
  @type produced :: %{
          topic: String.t(),
          partition: integer(),
          error_code: integer(),
          base_offset: integer()
        }

  @doc "A SaslHandshake v1 request that names the mechanism."
  @spec sasl_handshake(integer(), String.t(), String.t()) :: binary()
  def sasl_handshake(correlation, client_id, mechanism),
    do: request(@sasl_handshake, 1, correlation, client_id, string(mechanism))

  @doc "A SaslAuthenticate v0 request that carries one message of the mechanism."
  @spec sasl_authenticate(integer(), String.t(), binary()) :: binary()
  def sasl_authenticate(correlation, client_id, message),
    do: request(@sasl_authenticate, 0, correlation, client_id, bytes(message))

  @doc "A Metadata v4 request for one topic; the topic is never created by it."
  @spec metadata(integer(), String.t(), String.t()) :: binary()
  def metadata(correlation, client_id, topic),
    do: request(@metadata, 4, correlation, client_id, [<<1::32>>, string(topic), <<0>>])

  # WH-18
  @doc "A Produce v3 request with one record for one partition. `acks` is -1 for the acknowledgement of every in-sync replica; `timeout_ms` is how long the broker may wait for it."
  @spec produce(integer(), String.t(), String.t(), integer(), entry(), integer(), integer()) ::
          binary()
  def produce(correlation, client_id, topic, partition, record, acks, timeout_ms) do
    batch = record_batch(record)

    body = [
      <<-1::16-signed, acks::16-signed, timeout_ms::32-signed, 1::32>>,
      string(topic),
      <<1::32, partition::32-signed>>,
      bytes(batch)
    ]

    request(@produce, 3, correlation, client_id, body)
  end

  defp request(api_key, version, correlation, client_id, body) do
    header = [<<api_key::16, version::16, correlation::32-signed>>, string(client_id)]
    size = IO.iodata_length(header) + IO.iodata_length(body)
    IO.iodata_to_binary([<<size::32>>, header, body])
  end

  defp string(text), do: [<<byte_size(text)::16>>, text]

  defp bytes(binary), do: [<<byte_size(binary)::32>>, binary]

  @doc "A record batch of format v2 that holds the one record."
  @spec record_batch(entry()) :: binary()
  def record_batch(%{timestamp_ms: timestamp_ms} = record) do
    body = IO.iodata_to_binary(record_body(record))

    times = <<0::16, 0::32, timestamp_ms::64, timestamp_ms::64>>
    producer = <<-1::64-signed, -1::16-signed, -1::32-signed, 1::32>>
    checked = IO.iodata_to_binary([times, producer, varint(byte_size(body)), body])

    length = byte_size(checked) + 9
    <<0::64, length::32, -1::32-signed, 2, crc32c(checked)::32, checked::binary>>
  end

  defp record_body(%{key: key, value: value, headers: headers}) do
    [
      <<0>>,
      varint(0),
      varint(0),
      nullable(key),
      sized(value),
      varint(length(headers)),
      Enum.map(headers, fn {name, content} -> [sized(name), sized(content)] end)
    ]
  end

  defp nullable(nil), do: varint(-1)
  defp nullable(binary), do: sized(binary)

  defp sized(binary), do: [varint(byte_size(binary)), binary]

  @doc "The zigzag variable length encoding of a signed integer."
  @spec varint(integer()) :: binary()
  def varint(value) when is_integer(value) and value >= 0, do: unsigned(value * 2)
  def varint(value) when is_integer(value), do: unsigned(-value * 2 - 1)

  defp unsigned(value) when value < 0x80, do: <<value>>
  defp unsigned(value), do: <<1::1, band(value, 0x7F)::7, unsigned(value >>> 7)::binary>>

  @doc "The CRC-32C (Castagnoli) checksum of a binary."
  @spec crc32c(binary()) :: non_neg_integer()
  def crc32c(data) when is_binary(data), do: bxor(crc(data, @mask), @mask)

  defp crc(<<byte, rest::binary>>, crc),
    do: crc(rest, bxor(elem(@crc_table, band(bxor(crc, byte), 0xFF)), crc >>> 8))

  defp crc(<<>>, crc), do: crc

  # WH-20 (3)
  @doc "The 32 bit murmur2 hash of the Kafka clients, as an unsigned integer."
  @spec murmur2(binary()) :: non_neg_integer()
  def murmur2(data) when is_binary(data) do
    hash = mix(data, bxor(@murmur_seed, band(byte_size(data), @mask)))
    hash = times(bxor(hash, hash >>> 13))
    bxor(hash, hash >>> 15)
  end

  defp mix(<<block::little-32, rest::binary>>, hash) do
    block = times(block)
    block = times(bxor(block, block >>> 24))
    mix(rest, bxor(times(hash), block))
  end

  defp mix(<<>>, hash), do: hash

  defp mix(<<tail::little-8>>, hash), do: times(bxor(hash, tail))
  defp mix(<<tail::little-16>>, hash), do: times(bxor(hash, tail))
  defp mix(<<tail::little-24>>, hash), do: times(bxor(hash, tail))

  defp times(value), do: band(value * @murmur_m, @mask)

  # WH-20 (3)
  # AG-24
  @doc "The partition of a record key among `count` partitions, as the Java client chooses it."
  @spec partition(binary(), pos_integer()) :: non_neg_integer()
  def partition(key, count) when is_binary(key) and is_integer(count) and count > 0,
    do: rem(band(murmur2(key), 0x7FFFFFFF), count)

  @doc "The body of a response frame whose correlation id is the expected one."
  @spec response(binary(), integer()) :: {:ok, binary()} | :error
  def response(<<correlation::32-signed, body::binary>>, correlation), do: {:ok, body}
  def response(_frame, _correlation), do: :error

  @doc "Reads a SaslHandshake v1 response: the error code and the mechanisms the broker has."
  @spec decode_sasl_handshake(binary()) :: {:ok, integer(), [String.t()]} | :error
  def decode_sasl_handshake(<<error_code::16-signed, rest::binary>>) do
    case array(rest, &read_string/1) do
      {:ok, mechanisms, _rest} -> {:ok, error_code, mechanisms}
      :error -> :error
    end
  end

  def decode_sasl_handshake(_body), do: :error

  @doc "Reads a SaslAuthenticate v0 response: the error code and the message of the mechanism."
  @spec decode_sasl_authenticate(binary()) :: {:ok, integer(), binary()} | :error
  def decode_sasl_authenticate(<<error_code::16-signed, rest::binary>>) do
    with {:ok, _message, rest} <- read_nullable_string(rest),
         {:ok, message, _rest} <- read_bytes(rest) do
      {:ok, error_code, message}
    end
  end

  def decode_sasl_authenticate(_body), do: :error

  @doc "Reads a Metadata v4 response: the brokers by node id and the topics with their partitions."
  @spec decode_metadata(binary()) :: {:ok, metadata()} | :error
  def decode_metadata(<<_throttle::32, rest::binary>>) do
    with {:ok, brokers, rest} <- array(rest, &read_broker/1),
         {:ok, _cluster, <<_controller::32, rest::binary>>} <- read_nullable_string(rest),
         {:ok, topics, _rest} <- array(rest, &read_topic/1) do
      {:ok, %{brokers: Map.new(brokers), topics: topics}}
    else
      _unreadable -> :error
    end
  end

  def decode_metadata(_body), do: :error

  defp read_broker(<<node::32-signed, rest::binary>>) do
    with {:ok, host, <<port::32-signed, rest::binary>>} <- read_string(rest),
         {:ok, _rack, rest} <- read_nullable_string(rest) do
      {:ok, {node, {host, port}}, rest}
    else
      _unreadable -> :error
    end
  end

  defp read_broker(_binary), do: :error

  defp read_topic(<<error_code::16-signed, rest::binary>>) do
    with {:ok, name, <<_internal, rest::binary>>} <- read_string(rest),
         {:ok, partitions, rest} <- array(rest, &read_partition/1) do
      {:ok, %{error_code: error_code, name: name, partitions: partitions}, rest}
    else
      _unreadable -> :error
    end
  end

  defp read_topic(_binary), do: :error

  defp read_partition(<<head::binary-size(10), rest::binary>>) do
    <<error_code::16-signed, index::32-signed, leader::32-signed>> = head

    with {:ok, _replicas, rest} <- array(rest, &read_int32/1),
         {:ok, _in_sync, rest} <- array(rest, &read_int32/1) do
      {:ok, %{error_code: error_code, index: index, leader: leader}, rest}
    end
  end

  defp read_partition(_binary), do: :error

  @doc "Reads a Produce v3 response: one entry per partition the broker answered for."
  @spec decode_produce(binary()) :: {:ok, [produced()]} | :error
  def decode_produce(body) when is_binary(body) do
    case array(body, &read_produced_topic/1) do
      {:ok, topics, _rest} -> {:ok, List.flatten(topics)}
      :error -> :error
    end
  end

  defp read_produced_topic(binary) do
    with {:ok, topic, rest} <- read_string(binary),
         {:ok, partitions, rest} <- array(rest, &read_produced/1) do
      {:ok, Enum.map(partitions, &Map.put(&1, :topic, topic)), rest}
    end
  end

  defp read_produced(<<head::binary-size(22), rest::binary>>) do
    <<index::32-signed, error_code::16-signed, offset::64-signed, _time::64>> = head
    {:ok, %{partition: index, error_code: error_code, base_offset: offset}, rest}
  end

  defp read_produced(_binary), do: :error

  defp read_int32(<<value::32-signed, rest::binary>>), do: {:ok, value, rest}
  defp read_int32(_binary), do: :error

  defp read_string(<<length::16-signed, text::binary-size(length), rest::binary>>)
       when length >= 0,
       do: {:ok, text, rest}

  defp read_string(_binary), do: :error

  defp read_nullable_string(<<-1::16-signed, rest::binary>>), do: {:ok, nil, rest}
  defp read_nullable_string(binary), do: read_string(binary)

  defp read_bytes(<<length::32, data::binary-size(length), rest::binary>>)
       when length < 0x80000000,
       do: {:ok, data, rest}

  defp read_bytes(_binary), do: :error

  defp array(<<-1::32-signed, rest::binary>>, _reader), do: {:ok, [], rest}

  defp array(<<count::32, rest::binary>>, reader) when count < 0x80000000,
    do: items(count, rest, reader, [])

  defp array(_binary, _reader), do: :error

  defp items(0, rest, _reader, items), do: {:ok, Enum.reverse(items), rest}

  defp items(count, binary, reader, items) do
    case reader.(binary) do
      {:ok, item, rest} -> items(count - 1, rest, reader, [item | items])
      :error -> :error
    end
  end
end
