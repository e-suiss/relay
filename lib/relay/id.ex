defmodule Relay.Id do
  @moduledoc """
  UUIDv7 identifiers in the RFC 9562 layout: a 48-bit Unix millisecond timestamp, version 7, 12 random bits, the RFC variant and 62 random bits. Time comes from `Relay.Clock` and randomness from `Relay.Random`. Records sort by `created_at`, not by identifier.
  """

  @type t :: <<_::128>>

  @max_ms Integer.pow(2, 48) - 1

  # OP-1
  # T-60
  # T-57
  @doc "Generates a UUIDv7 from the clock and randomness ports."
  @spec generate() :: t()
  def generate do
    build(DateTime.to_unix(Relay.Clock.utc_now(), :millisecond), Relay.Random.bytes(10))
  end

  @doc "Builds a UUIDv7 from a Unix millisecond timestamp and 10 random bytes, of which 74 bits are used."
  @spec build(non_neg_integer(), <<_::80>>) :: t()
  def build(unix_ms, <<rand_a::12, rand_b::62, _unused::6>>)
      when is_integer(unix_ms) and unix_ms >= 0 and unix_ms <= @max_ms do
    <<unix_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
  end

  @doc "Returns true for a 16-byte value with UUID version 7 and the RFC 9562 variant."
  @spec valid?(term()) :: boolean()
  def valid?(<<_ms::48, 7::4, _rand_a::12, 2::2, _rand_b::62>>), do: true
  def valid?(_other), do: false

  @doc "Returns the Unix millisecond timestamp of a UUIDv7."
  @spec timestamp_ms(t()) :: non_neg_integer()
  def timestamp_ms(<<unix_ms::48, 7::4, _rand_a::12, 2::2, _rand_b::62>>), do: unix_ms

  @doc "Formats a UUIDv7 in the RFC 9562 hexadecimal text form, lowercase."
  @spec to_string(t()) :: String.t()
  def to_string(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>> = id) do
    true = valid?(id)
    Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
  end

  @doc "Parses the RFC 9562 hexadecimal text form of a UUIDv7; letter case is ignored."
  @spec parse(term()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def parse(<<a::binary-8, ?-, b::binary-4, ?-, c::binary-4, ?-, d::binary-4, ?-, e::binary-12>>) do
    with {:ok, id} <- Base.decode16(a <> b <> c <> d <> e, case: :mixed),
         true <- valid?(id) do
      {:ok, id}
    else
      _ -> invalid()
    end
  end

  def parse(_other), do: invalid()

  defp invalid, do: {:error, Relay.Error.new(:invalid_id, "not a UUIDv7")}
end
