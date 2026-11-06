defmodule RelayWeb.Api.Transport do
  @moduledoc """
  The transport rules of the API (API-8): HTTPS only, with HSTS on every answer, and the client address. Behind a TLS terminating proxy the scheme and the client address come from `X-Forwarded-Proto` and `X-Forwarded-For`, but only when the connection's peer is one of the proxies listed in `config :relay, RelayWeb.Api, trusted_proxies: [cidr]`; there is no setting that admits plain HTTP.

  The client certificate of an mTLS connection (RFC 8705) is the connection's own. Behind a proxy that terminates mTLS it comes from the RFC 9440 `Client-Cert` header (and `Client-Cert-Chain`), but only when the connection's peer is one of the proxies listed in `config :relay, RelayWeb.Api, client_cert_proxies: [cidr]` (E-79 (4)); the list is empty by default, and a header from any other peer, or one that is not a well-formed DER certificate, is ignored.
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

  # E-93
  @doc "The external URL of the request without query, which a DPoP proof's `htu` names: the scheme and host a trusted proxy forwarded (`X-Forwarded-Proto`, `X-Forwarded-Host`), else the connection's own, and the request path."
  @spec request_url(Plug.Conn.t(), [String.t()]) :: String.t()
  def request_url(conn, trusted \\ trusted_proxies()) do
    scheme = scheme(conn, trusted)
    Atom.to_string(scheme) <> "://" <> authority(conn, scheme, trusted) <> conn.request_path
  end

  defp authority(conn, scheme, trusted) do
    forwarded = Plug.Conn.get_req_header(conn, "x-forwarded-host")

    case {trusted?(conn.remote_ip, trusted), forwarded} do
      {true, [host | _]} -> host |> String.split(",") |> hd() |> String.trim()
      {true, []} when scheme != conn.scheme -> conn.host
      _own -> conn.host <> port(scheme, conn.port)
    end
  end

  defp port(:https, 443), do: ""
  defp port(:http, 80), do: ""
  defp port(_scheme, port), do: ":" <> Integer.to_string(port)

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

  # API-41
  # API-48
  # E-79 (4)
  @doc "The client certificate of the request as DER, or nil: the connection's own, else the RFC 9440 `Client-Cert` of a configured client certificate proxy."
  @spec client_certificate(Plug.Conn.t(), [String.t()]) :: binary() | nil
  def client_certificate(conn, proxies \\ client_cert_proxies()) do
    case Plug.Conn.get_peer_data(conn) do
      %{ssl_cert: der} when is_binary(der) -> der
      _plain -> forwarded_certificate(conn, proxies)
    end
  end

  defp forwarded_certificate(conn, proxies) do
    with true <- trusted?(conn.remote_ip, proxies),
         [value] <- Plug.Conn.get_req_header(conn, "client-cert"),
         {:ok, der} <- byte_sequence(value),
         true <- certificate?(der),
         {:ok, _chain} <- chain(Plug.Conn.get_req_header(conn, "client-cert-chain")) do
      der
    else
      _ignored -> nil
    end
  end

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

  @doc "The client certificate proxy ranges of the configuration; empty by default."
  @spec client_cert_proxies() :: [String.t()]
  def client_cert_proxies,
    do: :relay |> Application.get_env(RelayWeb.Api, []) |> Keyword.get(:client_cert_proxies, [])

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
