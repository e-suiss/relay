defmodule Relay.Webhooks.Destination.Rabbitmq.Frame do
  @moduledoc """
  The AMQP 0-9-1 frames of one confirmed publish (WH-17, WH-18). The module is pure: it encodes what a publisher sends and decodes what a broker answers, and nothing else of the protocol.

  A frame is a type, a channel, the size of its payload, the payload and the frame end octet. `method/2` encodes the methods a publisher sends, `content/4` the content header and the body frames of a message, split so that no frame is larger than the negotiated maximum. `decode/3` reads what follows the seven byte head that `head/1` read: a method the publisher waits for becomes `{name, arguments}`, a method it does not know becomes `{:other, %{}}`, and content and heartbeat frames are named as such.

  In a field table a binary is written as a long string, a boolean as a boolean and a list of pairs as a nested table.
  """

  @frame_end 0xCE
  @method 1
  @header 2
  @body 3
  @heartbeat 8
  @overhead 8
  @basic 60
  @property_flags 0xB080

  @type field :: {String.t(), binary() | boolean() | [field()]}
  @type start_ok :: %{
          properties: [field()],
          mechanism: String.t(),
          response: binary(),
          locale: String.t()
        }
  @type tune :: %{
          channel_max: non_neg_integer(),
          frame_max: non_neg_integer(),
          heartbeat: non_neg_integer()
        }
  @type publish :: %{exchange: String.t(), routing_key: String.t(), mandatory: boolean()}
  @type sent ::
          {:connection_start_ok, start_ok()}
          | {:connection_tune_ok, tune()}
          | {:connection_open, %{vhost: String.t()}}
          | {:connection_close, %{code: non_neg_integer(), text: String.t()}}
          | {:connection_close_ok, %{}}
          | {:channel_open, %{}}
          | {:channel_close_ok, %{}}
          | {:confirm_select, %{}}
          | {:basic_publish, publish()}
  @type properties :: %{
          content_type: String.t(),
          headers: [field()],
          delivery_mode: 1 | 2,
          message_id: String.t()
        }
  @type decoded :: {atom(), map()} | :content | :heartbeat

  @doc "The protocol header a client opens the connection with."
  @spec protocol_header() :: binary()
  def protocol_header, do: <<"AMQP", 0, 0, 9, 1>>

  @doc "The bytes a frame adds to its payload: the head and the frame end octet."
  @spec overhead() :: pos_integer()
  def overhead, do: @overhead

  @doc "Encodes a method frame on `channel`. Every short string must be at most 255 bytes."
  @spec method(non_neg_integer(), sent()) :: binary()
  def method(channel, {name, arguments}) when is_integer(channel) and is_atom(name) do
    frame(@method, channel, arguments(name, arguments))
  end

  defp arguments(:connection_start_ok, arguments) do
    [
      <<10::16, 11::16>>,
      table(arguments.properties),
      short(arguments.mechanism),
      long(arguments.response),
      short(arguments.locale)
    ]
  end

  defp arguments(:connection_tune_ok, arguments) do
    %{channel_max: channel_max, frame_max: frame_max, heartbeat: heartbeat} = arguments
    <<10::16, 31::16, channel_max::16, frame_max::32, heartbeat::16>>
  end

  defp arguments(:connection_open, arguments) do
    [<<10::16, 40::16>>, short(arguments.vhost), short(""), <<0>>]
  end

  defp arguments(:connection_close, arguments) do
    [<<10::16, 50::16, arguments.code::16>>, short(arguments.text), <<0::16, 0::16>>]
  end

  defp arguments(:connection_close_ok, _arguments), do: <<10::16, 51::16>>
  defp arguments(:channel_open, _arguments), do: [<<20::16, 10::16>>, short("")]
  defp arguments(:channel_close_ok, _arguments), do: <<20::16, 41::16>>
  defp arguments(:confirm_select, _arguments), do: <<85::16, 10::16, 0>>

  defp arguments(:basic_publish, arguments) do
    [
      <<@basic::16, 40::16, 0::16>>,
      short(arguments.exchange),
      short(arguments.routing_key),
      <<bit(arguments.mandatory)>>
    ]
  end

  # WH-18
  @doc "Encodes the content of a message on `channel`: the content header with its properties and the body in frames of at most `frame_max` bytes."
  @spec content(non_neg_integer(), properties(), binary(), pos_integer()) :: iodata()
  def content(channel, properties, body, frame_max)
      when is_binary(body) and is_integer(frame_max) and frame_max > @overhead do
    header = [
      <<@basic::16, 0::16, byte_size(body)::64, @property_flags::16>>,
      short(properties.content_type),
      table(properties.headers),
      <<properties.delivery_mode>>,
      short(properties.message_id)
    ]

    [frame(@header, channel, header) | chunks(body, frame_max - @overhead, channel)]
  end

  defp chunks(<<>>, _size, _channel), do: []

  defp chunks(body, size, channel) when byte_size(body) > size do
    chunk = binary_part(body, 0, size)
    rest = binary_part(body, size, byte_size(body) - size)
    [frame(@body, channel, chunk) | chunks(rest, size, channel)]
  end

  defp chunks(body, _size, channel), do: [frame(@body, channel, body)]

  defp frame(type, channel, payload) do
    payload = IO.iodata_to_binary(payload)
    <<type, channel::16, byte_size(payload)::32, payload::binary, @frame_end>>
  end

  defp short(text), do: <<byte_size(text), text::binary>>
  defp long(text), do: <<byte_size(text)::32, text::binary>>

  defp bit(true), do: 1
  defp bit(false), do: 0

  defp table(fields) do
    entries = Enum.map(fields, fn {name, value} -> [short(name), value(value)] end)
    long(IO.iodata_to_binary(entries))
  end

  defp value(value) when is_binary(value), do: [?S, long(value)]
  defp value(value) when is_boolean(value), do: [?t, bit(value)]
  defp value(value) when is_list(value), do: [?F, table(value)]

  @doc "Reads the seven byte head of a frame: its type, its channel and the size of its payload."
  @spec head(binary()) :: {:ok, {byte(), non_neg_integer(), non_neg_integer()}} | :error
  def head(<<type, channel::16, size::32>>), do: {:ok, {type, channel, size}}
  def head(_head), do: :error

  @doc "Decodes what follows the head of a frame of `type`: `size` bytes of payload and the frame end octet."
  @spec decode(byte(), non_neg_integer(), binary()) :: {:ok, decoded()} | :error
  def decode(type, size, rest)
      when is_integer(type) and is_integer(size) and byte_size(rest) == size + 1 do
    case {binary_part(rest, 0, size), binary_part(rest, size, 1)} do
      {payload, <<@frame_end>>} -> payload(type, payload)
      _unterminated -> :error
    end
  end

  def decode(_type, _size, _rest), do: :error

  defp payload(@method, <<class::16, method::16, arguments::binary>>) do
    received(class, method, arguments)
  end

  defp payload(@header, _payload), do: {:ok, :content}
  defp payload(@body, _payload), do: {:ok, :content}
  defp payload(@heartbeat, _payload), do: {:ok, :heartbeat}
  defp payload(_type, _payload), do: :error

  defp received(10, 10, arguments), do: start(arguments)

  defp received(10, 30, <<channel_max::16, frame_max::32, heartbeat::16>>) do
    tune = %{channel_max: channel_max, frame_max: frame_max, heartbeat: heartbeat}
    {:ok, {:connection_tune, tune}}
  end

  defp received(10, 41, _arguments), do: {:ok, {:connection_open_ok, %{}}}
  defp received(10, 50, arguments), do: close(:connection_close, arguments)
  defp received(10, 51, _arguments), do: {:ok, {:connection_close_ok, %{}}}
  defp received(20, 11, _arguments), do: {:ok, {:channel_open_ok, %{}}}
  defp received(20, 40, arguments), do: close(:channel_close, arguments)
  defp received(20, 41, _arguments), do: {:ok, {:channel_close_ok, %{}}}
  defp received(85, 11, _arguments), do: {:ok, {:confirm_select_ok, %{}}}

  defp received(@basic, 50, <<code::16, _rest::binary>>) do
    {:ok, {:basic_return, %{code: code}}}
  end

  defp received(@basic, 80, <<tag::64, _reserved::7, multiple::1>>) do
    {:ok, {:basic_ack, %{delivery_tag: tag, multiple: multiple == 1}}}
  end

  defp received(@basic, 120, <<tag::64, _reserved::6, _requeue::1, multiple::1>>) do
    {:ok, {:basic_nack, %{delivery_tag: tag, multiple: multiple == 1}}}
  end

  defp received(10, 30, _arguments), do: :error
  defp received(@basic, method, _arguments) when method in [50, 80, 120], do: :error
  defp received(_class, _method, _arguments), do: {:ok, {:other, %{}}}

  defp start(<<_major, _minor, size::32, _properties::binary-size(size), rest::binary>>) do
    mechanisms(rest)
  end

  defp start(_arguments), do: :error

  defp mechanisms(<<length::32, mechanisms::binary-size(length), _locales::binary>>) do
    {:ok, {:connection_start, %{mechanisms: String.split(mechanisms, " ", trim: true)}}}
  end

  defp mechanisms(_arguments), do: :error

  defp close(name, <<code::16, size, text::binary-size(size), _class::16, _method::16>>) do
    {:ok, {name, %{code: code, text: text}}}
  end

  defp close(_name, _arguments), do: :error
end
