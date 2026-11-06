defmodule RelayWeb.Api.Transport do
  @moduledoc """
  The transport rules of the API (API-8, E-91): HTTPS only, with HSTS on every answer, the request's scheme, host and client address, and its client certificate. Relay does not terminate TLS itself; the installation lists its trusted proxies in `RELAY_TRUSTED_PROXIES` (`config :relay, RelayWeb.Api, trusted_proxies: [cidr]`, empty by default). Only on a connection whose peer is in that list are `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Forwarded-For` and the RFC 9440 `Client-Cert` and `Client-Cert-Chain` read: the scheme and the host are the values the nearest proxy set (the last ones), and the client address is the nearest untrusted hop of `X-Forwarded-For`. From any other peer those headers are dropped. There is no setting that admits plain HTTP.

  `RelayWeb.Endpoint` applies `forward/2` once to every request; the readers below apply it themselves when it has not run, so they answer the same either way.

  The client certificate of an mTLS connection (RFC 8705) is the connection's own. Behind a proxy that terminates mTLS it is the `Client-Cert` (with `Client-Cert-Chain`) of a trusted proxy (E-79 (4)); one that is not a well-formed DER certificate is ignored.
  """

  import Bitwise

  @hsts "max-age=63072000; includeSubDomains"
  @peer :relay_transport_peer
  @forwarded [
    "x-forwarded-proto",
    "x-forwarded-host",
    "x-forwarded-for",
    "client-cert",
    "client-cert-chain"
  ]

  @doc "The HSTS header value."
  @spec hsts() :: String.t()
  def hsts, do: @hsts

  # API-8
  # E-91
  @doc "Applies the forwarded headers of a trusted proxy to the connection's scheme, host, port and client address, or drops them when the peer is not trusted. A connection it has already seen is returned unchanged."
  @spec forward(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def forward(conn, trusted \\ trusted_proxies())

  def forward(%Plug.Conn{private: %{@peer => _peer}} = conn, _trusted), do: conn

  def forward(conn, trusted) do
    peer = conn.remote_ip

    if trusted?(peer, trusted) do
      conn
      |> forwarded_scheme()
      |> forwarded_host()
      |> Map.put(:remote_ip, forwarded_for(conn, trusted))
      |> Plug.Conn.put_private(@peer, {:proxy, peer})
    else
      @forwarded
      |> Enum.reduce(conn, &Plug.Conn.delete_req_header(&2, &1))
      |> Plug.Conn.put_private(@peer, {:direct, peer})
    end
  end

  defp forwarded_scheme(conn) do
    case last_value(conn, "x-forwarded-proto") do
      nil -> conn
      proto -> scheme_of(conn, String.downcase(proto))
    end
  end

  defp scheme_of(conn, "https"), do: %{conn | scheme: :https, port: 443}
  defp scheme_of(conn, _other), do: %{conn | scheme: :http, port: 80}

  defp forwarded_host(conn) do
    case last_value(conn, "x-forwarded-host") do
      nil -> conn
      value -> host_of(conn, URI.new("//" <> value))
    end
  end

  defp host_of(conn, {:ok, %URI{host: host, port: port, userinfo: nil, path: path, query: nil}})
       when is_binary(host) and host != "" and path in [nil, ""],
       do: %{conn | host: host, port: port || conn.port}

  defp host_of(conn, _invalid), do: conn

  defp forwarded_for(conn, trusted) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-for")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reverse()
    |> Enum.flat_map(&parse_ip/1)
    |> Enum.find(conn.remote_ip, &(not trusted?(&1, trusted)))
  end

  defp last_value(conn, header) do
    conn
    |> Plug.Conn.get_req_header(header)
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> List.last()
  end

  # API-8
  # E-91
  @doc "The scheme the client used: the forwarded one from a trusted proxy, else the connection's own."
  @spec scheme(Plug.Conn.t(), [String.t()]) :: :http | :https
  def scheme(conn, trusted \\ trusted_proxies()), do: forward(conn, trusted).scheme

  # API-47
  # E-91
  @doc "The client address: the nearest untrusted hop of `X-Forwarded-For` behind trusted proxies, else the peer."
  @spec client_ip(Plug.Conn.t(), [String.t()]) :: :inet.ip_address()
  def client_ip(conn, trusted \\ trusted_proxies()), do: forward(conn, trusted).remote_ip

  # API-41
  # API-48
  # E-79 (4)
  # E-91
  @doc "The client certificate of the request as DER, or nil: the connection's own, else the RFC 9440 `Client-Cert` of a trusted proxy."
  @spec client_certificate(Plug.Conn.t(), [String.t()]) :: binary() | nil
  def client_certificate(conn, trusted \\ trusted_proxies()) do
    case Plug.Conn.get_peer_data(conn) do
      %{ssl_cert: der} when is_binary(der) -> der
      _plain -> forwarded_certificate(forward(conn, trusted))
    end
  end

  defp forwarded_certificate(%Plug.Conn{private: %{@peer => {:proxy, _peer}}} = conn) do
    with [value] <- Plug.Conn.get_req_header(conn, "client-cert"),
         {:ok, der} <- byte_sequence(value),
         true <- certificate?(der),
         {:ok, _chain} <- chain(Plug.Conn.get_req_header(conn, "client-cert-chain")) do
      der
    else
      _ignored -> nil
    end
  end

  defp forwarded_certificate(_conn), do: nil

  defp chain([]), do: {:ok, []}

  defp chain(values) do
    values
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.reduce_while({:ok, []}, fn member, {:ok, acc} ->
      with {:ok, der} <- byte_sequence(member),
           true <- certificate?(der) do
        {:cont, {:ok, [der | acc]}}
      else
        _malformed -> {:halt, :error}
      end
    end)
  end

  defp byte_sequence(value) do
    case Regex.run(~r/\A[ \t]*:([A-Za-z0-9+\/]*={0,2}):[ \t]*\z/, value) do
      [_, encoded] when encoded != "" -> Base.decode64(encoded)
      _malformed -> :error
    end
  end

  defp certificate?(der) do
    match?({:Certificate, _, _, _}, :public_key.pkix_decode_cert(der, :plain))
  rescue
    _malformed -> false
  end

  # E-91
  @doc "The trusted proxy ranges of the configuration; empty by default."
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
