defmodule Relay.Webhooks.Destination.KafkaProtocolTest do
  use ExUnit.Case, async: true

  alias Relay.Webhooks.Destination.Kafka.Protocol

  defp signed(value) when value >= 0x80000000, do: value - 0x100000000
  defp signed(value), do: value

  describe "WH-20 partitioner" do
    test "WH-20: murmur2 gives the values of the Kafka clients" do
      known = [
        {"21", -973_932_308},
        {"foobar", -790_332_482},
        {"a-little-bit-long-string", -985_981_536},
        {"a-little-bit-longer-string", -1_486_304_829},
        {"lkjh234lh9fiuh90y23oiuhsafujhadof229phr9h19h89h8", -58_897_971},
        {"abc", 479_470_107}
      ]

      for {key, hash} <- known do
        assert signed(Protocol.murmur2(key)) == hash
      end
    end

    test "WH-20, AG-24: a key always has the same partition, inside the partition count" do
      assert Protocol.partition("order/o-1", 3) == 0
      assert Protocol.partition("order/o-2", 3) == 1
      assert Protocol.partition("evt_1", 12) == 10

      for count <- 1..16, key <- ["a", "order/o-1", "", "ü"] do
        partition = Protocol.partition(key, count)
        assert partition in 0..(count - 1)
        assert partition == Protocol.partition(key, count)
      end
    end
  end

  describe "WH-18 produce framing" do
    test "WH-18: CRC-32C has the check value of the Castagnoli polynomial" do
      assert Protocol.crc32c("123456789") == 0xE3069283
      assert Protocol.crc32c("") == 0
    end

    test "WH-18: integers are written as zigzag varints" do
      assert Protocol.varint(0) == <<0>>
      assert Protocol.varint(-1) == <<1>>
      assert Protocol.varint(1) == <<2>>
      assert Protocol.varint(63) == <<126>>
      assert Protocol.varint(64) == <<128, 1>>
      assert Protocol.varint(-64) == <<127>>
      assert Protocol.varint(300) == <<216, 4>>
    end

    test "WH-18: a record batch is laid out as format v2" do
      record = %{key: "k", value: "vv", headers: [{"h", "x"}], timestamp_ms: 1_700_000_000_000}
      batch = Protocol.record_batch(record)

      body = <<0, 0, 0, 2, "k", 4, "vv", 2, 2, "h", 2, "x">>
      times = <<0::16, 0::32, 1_700_000_000_000::64, 1_700_000_000_000::64>>
      producer = <<-1::64-signed, -1::16-signed, -1::32-signed, 1::32>>
      checked = times <> producer <> <<26>> <> body
      head = <<0::64, byte_size(checked) + 9::32, -1::32-signed, 2>>

      assert byte_size(body) == 13
      assert batch == head <> <<Protocol.crc32c(checked)::32>> <> checked
    end

    test "WH-18: a record without a key has the null key" do
      record = %{key: nil, value: "v", headers: [], timestamp_ms: 0}
      batch = Protocol.record_batch(record)

      assert binary_part(batch, byte_size(batch) - 8, 8) == <<14, 0, 0, 0, 1, 2, "v", 0>>
    end

    test "WH-18: a produce request is version 3 with the acknowledgement of all replicas" do
      record = %{key: nil, value: "v", headers: [], timestamp_ms: 0}
      batch = Protocol.record_batch(record)
      request = IO.iodata_to_binary(Protocol.produce(5, "relay", "t1", 2, record, -1, 30_000))

      header = <<0::16, 3::16, 5::32, 5::16, "relay">>
      settings = <<-1::16-signed, -1::16-signed, 30_000::32>>
      topic = <<1::32, 2::16, "t1", 1::32, 2::32>>
      body = header <> settings <> topic <> <<byte_size(batch)::32>> <> batch

      assert request == <<byte_size(body)::32>> <> body
    end

    test "WH-18: a produce response is read per partition" do
      first = <<0::32, 0::16, 7::64, -1::64-signed>>
      second = <<1::32, 6::16, -1::64-signed, -1::64-signed>>
      body = <<1::32, 2::16, "t1", 2::32>> <> first <> second <> <<0::32>>

      assert {:ok, [first, second]} = Protocol.decode_produce(body)
      assert first == %{topic: "t1", partition: 0, error_code: 0, base_offset: 7}
      assert second == %{topic: "t1", partition: 1, error_code: 6, base_offset: -1}
      assert :error = Protocol.decode_produce(binary_part(body, 0, 20))
      assert :error = Protocol.decode_produce(<<255, 255, 255, 0>>)
    end
  end

  describe "WH-17 requests and responses" do
    test "WH-17: the SASL requests carry header v1 and their versions" do
      handshake = IO.iodata_to_binary(Protocol.sasl_handshake(1, "relay", "PLAIN"))
      assert handshake == <<22::32, 17::16, 1::16, 1::32, 5::16, "relay", 5::16, "PLAIN">>

      authenticate = IO.iodata_to_binary(Protocol.sasl_authenticate(2, "relay", "abc"))
      assert authenticate == <<22::32, 36::16, 0::16, 2::32, 5::16, "relay", 3::32, "abc">>
    end

    test "WH-17: the SASL responses are read" do
      offered = <<0::16, 2::32, 5::16, "PLAIN", 13::16, "SCRAM-SHA-256">>
      assert {:ok, 0, ["PLAIN", "SCRAM-SHA-256"]} = Protocol.decode_sasl_handshake(offered)
      assert {:ok, 33, []} = Protocol.decode_sasl_handshake(<<33::16, 0::32>>)
      assert :error = Protocol.decode_sasl_handshake(<<0>>)

      accepted = <<0::16, -1::16-signed, 3::32, "abc">>
      assert {:ok, 0, "abc"} = Protocol.decode_sasl_authenticate(accepted)

      refused = <<58::16, 3::16, "bad", 0::32>>
      assert {:ok, 58, ""} = Protocol.decode_sasl_authenticate(refused)

      short = <<0::16, -1::16-signed, 9::32, "abc">>
      assert :error = Protocol.decode_sasl_authenticate(short)
    end

    test "WH-17: a metadata request is version 4 and does not create the topic" do
      request = IO.iodata_to_binary(Protocol.metadata(4, "relay", "t1"))

      assert request == <<24::32, 3::16, 4::16, 4::32, 5::16, "relay", 1::32, 2::16, "t1", 0>>
    end

    test "WH-17: a metadata response gives the brokers and the leaders" do
      brokers = <<2::32, 1::32, 2::16, "b1", 9093::32, -1::16-signed, 2::32, 2::16, "b2">>
      rack = <<9094::32, 2::16, "r1">>
      cluster = <<3::16, "cid", 1::32>>
      partition = <<9::16, 0::32, 2::32, 2::32, 1::32, 2::32, 1::32, 2::32>>
      topics = <<1::32, 0::16, 2::16, "t1", 0, 1::32, partition::binary>>
      body = <<0::32, brokers::binary, rack::binary, cluster::binary, topics::binary>>

      assert {:ok, metadata} = Protocol.decode_metadata(body)
      assert metadata.brokers == %{1 => {"b1", 9093}, 2 => {"b2", 9094}}

      assert [%{error_code: 0, name: "t1", partitions: [led]}] = metadata.topics
      assert led == %{error_code: 9, index: 0, leader: 2}

      assert :error = Protocol.decode_metadata(binary_part(body, 0, byte_size(body) - 3))
      assert :error = Protocol.decode_metadata(<<0::32, 5::32>>)
    end

    test "WH-17: a response is matched by its correlation id" do
      assert {:ok, "body"} = Protocol.response(<<7::32, "body">>, 7)
      assert :error = Protocol.response(<<8::32, "body">>, 7)
      assert :error = Protocol.response(<<7::16>>, 7)
    end
  end
end
