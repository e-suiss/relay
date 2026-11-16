defmodule Relay.Webhooks.Egress.Address do
  @moduledoc """
  IP addresses, CIDR ranges and host names of the egress boundary (WH-40, WH-41). The module is pure: nothing here resolves a name.

  Addresses are parsed strictly: an IPv4 address is four decimal fields without leading zeros, so the octal, hexadecimal and shortened forms some resolvers accept are not addresses here. An IPv4-mapped IPv6 address is reduced to its IPv4 form by `canonical/1` before any check, and the IPv4 addresses carried inside IPv4-compatible, NAT64 (well-known and local-use prefix), 6to4 and Teredo addresses are returned by `embedded/1` so that they are checked as well.
  """

  import Bitwise

  @type ip :: :inet.ip_address()
  @type cidr :: {4 | 6, non_neg_integer(), non_neg_integer()}

  @ipv4 ~r/\A(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}\z/
  @ipv6 ~r/\A[0-9A-Fa-f:.]{2,45}\z/
  @prefix ~r/\A(?:0|[1-9][0-9]{0,2})\z/
  @name ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/
  @numeric ~r/\A(?:[0-9]+|0x[0-9a-f]*)\z/

  # WH-41
  @doc "Parses the strict text form of an IPv4 or IPv6 address."
  @spec parse(String.t()) :: {:ok, ip()} | :error
  def parse(text) when is_binary(text) do
    cond do
      Regex.match?(@ipv4, text) -> strict(text, &:inet.parse_ipv4strict_address/1)
      Regex.match?(@ipv6, text) -> strict(text, &:inet.parse_ipv6strict_address/1)
      true -> :error
    end
  end

  defp strict(text, parser) do
    case parser.(String.to_charlist(text)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> :error
    end
  end

  # WH-41
  @doc "Parses a CIDR range, or a single address as the range that holds only it. Host bits of the base are cleared."
  @spec parse_cidr(String.t()) :: {:ok, cidr()} | :error
  def parse_cidr(text) when is_binary(text) do
    case String.split(text, "/") do
      [address] -> range(parse(address), nil)
      [address, prefix] -> range(parse(address), prefix)
      _other -> :error
    end
  end

  defp range(:error, _prefix), do: :error

  defp range({:ok, ip}, nil) do
    {family, value} = number(ip)
    {:ok, {family, value, bits(family)}}
  end

  defp range({:ok, ip}, prefix) do
    {family, value} = number(ip)
    size = bits(family)

    if Regex.match?(@prefix, prefix) and String.to_integer(prefix) <= size do
      shift = size - String.to_integer(prefix)
      {:ok, {family, value >>> shift <<< shift, size - shift}}
    else
      :error
    end
  end

  @doc "Whether the address lies inside the range. An address of the other family never does."
  @spec member?(ip(), cidr()) :: boolean()
  def member?(ip, {family, base, prefix}) do
    case number(ip) do
      {^family, value} -> value >>> (bits(family) - prefix) == base >>> (bits(family) - prefix)
      _other -> false
    end
  end

  @doc "Whether two ranges share an address."
  @spec overlap?(cidr(), cidr()) :: boolean()
  def overlap?({family, left, left_prefix}, {family, right, right_prefix}) do
    shift = bits(family) - min(left_prefix, right_prefix)
    left >>> shift == right >>> shift
  end

  def overlap?({_left_family, _left, _left_prefix}, {_right_family, _right, _right_prefix}),
    do: false

  # WH-41 (2)
  @doc "Reduces an IPv4-mapped IPv6 address to its IPv4 form; any other address is returned as it is."
  @spec canonical(ip()) :: ip()
  def canonical({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: ipv4(high, low)
  def canonical(ip) when tuple_size(ip) in [4, 8], do: ip

  # WH-41 (2)
  @doc "The IPv4 addresses an IPv6 transition address carries: IPv4-compatible, NAT64, 6to4 and Teredo (server and client)."
  @spec embedded(ip()) :: [:inet.ip4_address()]
  def embedded({0, 0, 0, 0, 0, 0, 0, low}) when low in [0, 1], do: []
  def embedded({0, 0, 0, 0, 0, 0, high, low}), do: [ipv4(high, low)]
  def embedded({0x64, 0xFF9B, 0, 0, 0, 0, high, low}), do: [ipv4(high, low)]
  def embedded({0x64, 0xFF9B, 1, _d, _e, _f, high, low}), do: [ipv4(high, low)]
  def embedded({0x2002, high, low, _d, _e, _f, _g, _h}), do: [ipv4(high, low)]

  def embedded({0x2001, 0, server_high, server_low, _e, _f, client_high, client_low}) do
    client = ipv4(bxor(client_high, 0xFFFF), bxor(client_low, 0xFFFF))
    [ipv4(server_high, server_low), client]
  end

  def embedded(ip) when tuple_size(ip) in [4, 8], do: []

  @doc "The text form of an address."
  @spec to_text(ip()) :: String.t()
  def to_text(ip) when tuple_size(ip) in [4, 8], do: ip |> :inet.ntoa() |> List.to_string()

  # WH-40
  @doc "Normalises a DNS host name: lower case, without the final dot, letters, digits and hyphens in labels of at most 63 bytes, at most 253 bytes in all. A name whose last label is a number is refused, because resolvers read it as an address."
  @spec name(String.t()) :: {:ok, String.t()} | :error
  def name(text) when is_binary(text) do
    name = text |> String.downcase(:ascii) |> String.replace_suffix(".", "")

    if byte_size(name) <= 253 and Regex.match?(@name, name) and not numeric_end?(name),
      do: {:ok, name},
      else: :error
  end

  defp numeric_end?(name), do: Regex.match?(@numeric, name |> String.split(".") |> List.last())

  defp ipv4(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp number({a, b, c, d}) do
    <<value::32>> = <<a, b, c, d>>
    {4, value}
  end

  defp number({a, b, c, d, e, f, g, h}) do
    <<value::128>> = <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    {6, value}
  end

  defp bits(4), do: 32
  defp bits(6), do: 128
end
