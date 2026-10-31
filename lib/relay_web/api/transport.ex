defmodule RelayWeb.Api.Transport do
  @moduledoc """
  The transport rules of the API (API-8): HTTPS only, with HSTS on every answer, and the client address. Behind a TLS terminating proxy the scheme and the client address come from `X-Forwarded-Proto` and `X-Forwarded-For`, but only when the connection's peer is one of the proxies listed in `config :relay, RelayWeb.Api, trusted_proxies: [cidr]`; there is no setting that admits plain HTTP.
  """

  import Bitwise

  @hsts "max-age=63072000; includeSubDomains"

  @doc "The HSTS header value."
  @spec hsts() :: String.t()
  def hsts, do: @hsts

  # API-8
  @doc "The scheme the client used: the forwarded one from a trusted proxy, else the connection's own."
  @spec scheme(Plug.Conn.t(), [String.t()]) :: :http | :https
  def scheme(conn, trusted \\ trusted_proxies()) do
    forwarded = Plug.Conn.get_req_header(conn, "x-forwarded-proto")

    case {trusted?(conn.remote_ip, trusted), forwarded} do
      {true, [proto | _]} -> forwarded_scheme(proto)
      _ -> conn.scheme
    end
  end

  defp forwarded_scheme(proto) do
    if String.downcase(String.trim(proto)) == "https", do: :https, else: :http
  end

  # API-47
  @doc "The client address: the nearest untrusted hop of `X-Forwarded-For` behind trusted proxies, else the peer."
  @spec client_ip(Plug.Conn.t(), [String.t()]) :: :inet.ip_address()
  def client_ip(conn, trusted \\ trusted_proxies()) do
    if trusted?(conn.remote_ip, trusted) do
      conn
      |> Plug.Conn.get_req_header("x-forwarded-for")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reverse()
      |> Enum.flat_map(&parse_ip/1)
      |> Enum.find(conn.remote_ip, &(not trusted?(&1, trusted)))
    else
      conn.remote_ip
    end
  end

  @doc "The trusted proxy ranges of the configuration."
  @spec trusted_proxies() :: [String.t()]
  def trusted_proxies,
    do: :relay |> Application.get_env(RelayWeb.Api, []) |> Keyword.get(:trusted_proxies, [])

  @doc "Whether an address lies in one of the CIDR ranges."
  @spec trusted?(:inet.ip_address() | nil, [String.t()]) :: boolean()
  def trusted?(nil, _ranges), do: false
  def trusted?(ip, ranges), do: Enum.any?(ranges, &in_range?(ip, &1))

  defp in_range?(ip, range) do
    {address, bits} =
      case String.split(range, "/", parts: 2) do
        [address, bits] -> {address, Integer.parse(bits)}
        [address] -> {address, :all}
      end

    with [network] <- parse_ip(address),
         true <- tuple_size(network) == tuple_size(ip) do
      size = tuple_size(ip) * if(tuple_size(ip) == 4, do: 8, else: 16)

      prefix =
        case bits do
          {n, ""} when n >= 0 and n <= size -> n
          _ -> size
        end

      mask(to_integer(ip), size, prefix) == mask(to_integer(network), size, prefix)
    else
      _ -> false
    end
  end

  defp mask(value, size, prefix), do: value >>> (size - prefix)

  defp to_integer(ip) when tuple_size(ip) == 4,
    do: ip |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< 8 ||| &1))

  defp to_integer(ip), do: ip |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< 16 ||| &1))

  defp parse_ip(text) do
    case :inet.parse_strict_address(String.to_charlist(text)) do
      {:ok, ip} -> [ip]
      {:error, _} -> []
    end
  end
end
