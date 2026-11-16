defmodule Relay.Webhooks.Destination.RabbitmqFrameTest do
  use ExUnit.Case, async: true

  alias Relay.Webhooks.Destination.Rabbitmq.Frame

  @frame_end 0xCE

  defp decode(<<head::binary-size(7), rest::binary>>) do
    {:ok, {type, _channel, size}} = Frame.head(head)
    Frame.decode(type, size, rest)
  end

  defp method(channel, payload),
    do: <<1, channel::16, byte_size(payload)::32, payload::binary, @frame_end>>

  describe "WH-17 frames a publisher sends" do
    test "WH-17: the protocol header names AMQP 0-9-1" do
      assert Frame.protocol_header() == <<"AMQP", 0, 0, 9, 1>>
    end

    test "WH-17: start-ok carries the client properties, the mechanism and the response" do
      properties = [{"product", "relay"}, {"capabilities", [{"basic.nack", true}]}]

      start_ok = %{
        properties: properties,
        mechanism: "PLAIN",
        response: <<0, "u", 0, "p">>,
        locale: "en_US"
      }

      capabilities = <<10, "basic.nack", ?t, 1>>
      product = <<7, "product", ?S, 5::32, "relay">>
      nested = <<12, "capabilities", ?F, byte_size(capabilities)::32, capabilities::binary>>
      table = product <> nested
      head = <<10::16, 11::16, byte_size(table)::32, table::binary>>
      payload = head <> <<5, "PLAIN", 4::32, 0, "u", 0, "p", 5, "en_US">>

      assert Frame.method(0, {:connection_start_ok, start_ok}) == method(0, payload)
    end

    test "WH-17: tune-ok, open and close are encoded field by field" do
      tune = %{channel_max: 1, frame_max: 4096, heartbeat: 0}

      assert Frame.method(0, {:connection_tune_ok, tune}) ==
               <<1, 0::16, 12::32, 10::16, 31::16, 1::16, 4096::32, 0::16, @frame_end>>

      assert Frame.method(0, {:connection_open, %{vhost: "/"}}) ==
               method(0, <<10::16, 40::16, 1, "/", 0, 0>>)

      assert Frame.method(0, {:connection_close, %{code: 200, text: "done"}}) ==
               method(0, <<10::16, 50::16, 200::16, 4, "done", 0::16, 0::16>>)

      assert Frame.method(0, {:connection_close_ok, %{}}) == method(0, <<10::16, 51::16>>)
      assert Frame.method(1, {:channel_open, %{}}) == method(1, <<20::16, 10::16, 0>>)
      assert Frame.method(1, {:channel_close_ok, %{}}) == method(1, <<20::16, 41::16>>)
      assert Frame.method(1, {:confirm_select, %{}}) == method(1, <<85::16, 10::16, 0>>)
    end

    test "WH-18: a publish names the exchange, the routing key and the mandatory flag" do
      publish = %{exchange: "events", routing_key: "a.b", mandatory: true}

      assert Frame.method(1, {:basic_publish, publish}) ==
               method(1, <<60::16, 40::16, 0::16, 6, "events", 3, "a.b", 1>>)

      assert Frame.method(1, {:basic_publish, %{publish | mandatory: false}}) ==
               method(1, <<60::16, 40::16, 0::16, 6, "events", 3, "a.b", 0>>)
    end

    test "WH-18: the content header carries the properties and the body is split" do
      properties = %{
        content_type: "application/json",
        headers: [{"cloudEvents:id", "evt_1"}],
        delivery_mode: 2,
        message_id: "evt_1"
      }

      body = String.duplicate("x", 25)
      table = <<14, "cloudEvents:id", ?S, 5::32, "evt_1">>

      fixed = <<60::16, 0::16, 25::64, 0xB080::16, 16, "application/json">>
      header = fixed <> <<byte_size(table)::32, table::binary, 2, 5, "evt_1">>

      expected = [
        <<2, 1::16, byte_size(header)::32, header::binary, @frame_end>>,
        <<3, 1::16, 10::32, String.duplicate("x", 10)::binary, @frame_end>>,
        <<3, 1::16, 10::32, String.duplicate("x", 10)::binary, @frame_end>>,
        <<3, 1::16, 5::32, "xxxxx", @frame_end>>
      ]

      encoded = Frame.content(1, properties, body, Frame.overhead() + 10)
      assert IO.iodata_to_binary(encoded) == IO.iodata_to_binary(expected)
    end

    test "WH-18: an empty body has a content header and no body frame" do
      properties = %{content_type: "a/b", headers: [], delivery_mode: 2, message_id: "m"}
      header = <<60::16, 0::16, 0::64, 0xB080::16, 3, "a/b", 0::32, 2, 1, "m">>

      assert IO.iodata_to_binary(Frame.content(1, properties, "", 4096)) ==
               <<2, 1::16, byte_size(header)::32, header::binary, @frame_end>>
    end
  end

  describe "WH-18 frames a broker answers with" do
    test "WH-18: ack and nack carry the delivery tag" do
      assert decode(method(1, <<60::16, 80::16, 7::64, 1>>)) ==
               {:ok, {:basic_ack, %{delivery_tag: 7, multiple: true}}}

      assert decode(method(1, <<60::16, 120::16, 7::64, 0>>)) ==
               {:ok, {:basic_nack, %{delivery_tag: 7, multiple: false}}}
    end

    test "WH-18: a returned message carries the reply code" do
      returned = <<60::16, 50::16, 312::16, 8, "NO_ROUTE", 6, "events", 0>>
      assert decode(method(1, returned)) == {:ok, {:basic_return, %{code: 312}}}
    end

    test "WH-17: start lists the mechanisms and tune the limits" do
      start = <<10::16, 10::16, 0, 9, 3::32, 1, 2, 3, 14::32, "PLAIN EXTERNAL", 5::32, "en_US">>

      assert decode(method(0, start)) ==
               {:ok, {:connection_start, %{mechanisms: ["PLAIN", "EXTERNAL"]}}}

      assert decode(method(0, <<10::16, 30::16, 2047::16, 131_072::32, 60::16>>)) ==
               {:ok, {:connection_tune, %{channel_max: 2047, frame_max: 131_072, heartbeat: 60}}}
    end

    test "WH-18: a close carries the reply code and text" do
      close = <<404::16, 9, "NOT_FOUND", 60::16, 40::16>>

      assert decode(method(1, <<20::16, 40::16, close::binary>>)) ==
               {:ok, {:channel_close, %{code: 404, text: "NOT_FOUND"}}}

      assert decode(method(0, <<10::16, 50::16, close::binary>>)) ==
               {:ok, {:connection_close, %{code: 404, text: "NOT_FOUND"}}}
    end

    test "WH-18: the answers without arguments are named" do
      assert decode(method(0, <<10::16, 41::16, 0>>)) == {:ok, {:connection_open_ok, %{}}}
      assert decode(method(0, <<10::16, 51::16>>)) == {:ok, {:connection_close_ok, %{}}}
      assert decode(method(1, <<20::16, 11::16, 0::32>>)) == {:ok, {:channel_open_ok, %{}}}
      assert decode(method(1, <<85::16, 11::16>>)) == {:ok, {:confirm_select_ok, %{}}}
    end

    test "WH-18: content, heartbeat and unknown methods are told apart" do
      assert decode(<<2, 1::16, 2::32, 0, 0, @frame_end>>) == {:ok, :content}
      assert decode(<<3, 1::16, 2::32, "ab", @frame_end>>) == {:ok, :content}
      assert decode(<<8, 0::16, 0::32, @frame_end>>) == {:ok, :heartbeat}
      assert decode(method(0, <<10::16, 60::16, 2, "no">>)) == {:ok, {:other, %{}}}
    end

    test "WH-18: a frame that is cut short or not terminated is not decoded" do
      assert decode(<<1, 1::16, 13::32, 60::16, 80::16, 7::64, 1, 0>>) == :error
      assert decode(method(1, <<60::16, 80::16, 7::32>>)) == :error
      assert decode(method(0, <<10::16, 30::16, 1>>)) == :error
      assert decode(method(0, <<10::16, 10::16, 0, 9, 99::32, 1>>)) == :error
      assert decode(<<9, 0::16, 0::32, @frame_end>>) == :error
      assert Frame.decode(1, 4, <<1, 2>>) == :error
      assert Frame.head(<<1, 2, 3>>) == :error
    end
  end
end
