defmodule Relay.Webhooks.Egress.Transport.Pinned do
  @moduledoc """
  The production transport of the egress boundary, on Mint over HTTP/1.1 (WH-41 (1), WH-42 (3), WH-24).

  The connection is opened to the validated IP address, and the original host name is passed as Mint's `:hostname`: it is the SNI name, the `Host` header and the name the certificate is verified against, with the operating system's CA store unless the caller gives its own. Nothing is resolved here, so a name that changes its address after validation cannot move the connection. With an egress proxy the `CONNECT` request names the validated address as well.

  One request is sent on one connection, which is closed afterwards. A redirect is returned as the response it is. Every wait is bounded by the total deadline; the connection and the TLS handshake are each bounded by the connect timeout. Reading stops once more than `max_response_bytes` of the body have arrived, and the rest is discarded with the connection.
  """

  @behaviour Relay.Webhooks.Egress.Transport

  alias Relay.Clock
  alias Relay.Redacted

  @empty %{status: nil, headers: [], body: [], size: 0, done: false}

  # WH-41 (1)
  # WH-42 (3)
  @impl Relay.Webhooks.Egress.Transport
  def request(connection, request) do
    deadline = Clock.monotonic_ms() + connection.total_timeout_ms

    case Mint.HTTP.connect(:https, connection.address, connection.port, options(connection)) do
      {:ok, conn} -> exchange(conn, request, connection.max_response_bytes, deadline)
      {:error, error} -> {:error, failure(error)}
    end
  end

  defp options(connection) do
    transport_opts = transport_opts(connection)

    options = [
      hostname: connection.host,
      mode: :passive,
      protocols: [:http1],
      transport_opts: transport_opts
    ]

    case connection.proxy do
      nil ->
        options

      {scheme, host, port} ->
        proxy_opts = [transport_opts: Keyword.take(transport_opts, [:timeout])]
        Keyword.put(options, :proxy, {scheme, host, port, proxy_opts})
    end
  end

  defp transport_opts(connection) do
    timeout = min(connection.connect_timeout_ms, connection.total_timeout_ms)

    [timeout: timeout, verify: :verify_peer]
    |> family(connection.address)
    |> trust(connection.ca_certificates)
    |> identity(connection.client_certificate)
  end

  defp family(opts, address) when tuple_size(address) == 8,
    do: opts ++ [inet6: true, inet4: false]

  defp family(opts, _address), do: opts

  defp trust(opts, nil), do: opts
  defp trust(opts, certificates), do: opts ++ [cacerts: certificates]

  defp identity(opts, nil), do: opts

  defp identity(opts, %{certificate: certificate, key: key}),
    do: opts ++ [cert: certificate, key: Redacted.expose(key)]

  defp exchange(conn, request, max, deadline) do
    %{method: method, path: path, headers: headers, body: body} = request

    case Mint.HTTP.request(conn, method, path, headers, IO.iodata_to_binary(body)) do
      {:ok, conn, ref} -> receive_response(conn, ref, @empty, max, deadline)
      {:error, conn, error} -> close(conn, @empty, max, failure(error))
    end
  end

  # WH-24
  defp receive_response(conn, ref, acc, max, deadline) do
    remaining = deadline - Clock.monotonic_ms()

    if remaining > 0 do
      conn |> Mint.HTTP.recv(0, remaining) |> received(ref, acc, max, deadline)
    else
      close(conn, acc, max, %{class: :timeout, reason: "total_timeout"})
    end
  end

  defp received({:ok, conn, responses}, ref, acc, max, deadline) do
    case Enum.reduce(responses, acc, &fold(&1, &2, ref)) do
      %{done: false, size: size} = acc when size <= max ->
        receive_response(conn, ref, acc, max, deadline)

      acc ->
        close(conn, acc, max, %{class: :protocol, reason: "incomplete_response"})
    end
  end

  defp received({:error, conn, error, responses}, ref, acc, max, _deadline) do
    acc = Enum.reduce(responses, acc, &fold(&1, &2, ref))
    close(conn, acc, max, failure(error))
  end

  defp fold({:status, ref, status}, _acc, ref), do: %{@empty | status: status}
  defp fold({:headers, ref, headers}, %{headers: []} = acc, ref), do: %{acc | headers: headers}

  defp fold({:data, ref, data}, acc, ref),
    do: %{acc | body: [acc.body, data], size: acc.size + byte_size(data)}

  defp fold({:done, ref}, acc, ref), do: %{acc | done: true}
  defp fold({:error, ref, _reason}, acc, ref), do: %{acc | done: true}
  defp fold(_response, acc, _ref), do: acc

  defp close(conn, acc, max, error) do
    {:ok, _conn} = Mint.HTTP.close(conn)
    response(acc, max, error)
  end

  defp response(%{status: status} = acc, max, _error) when is_integer(status) and status >= 200 do
    body = IO.iodata_to_binary(acc.body)
    kept = Relay.Binary.keep(binary_part(body, 0, min(byte_size(body), max)))
    truncated = acc.size > max or not acc.done
    {:ok, %{status: status, headers: acc.headers, body: kept, truncated: truncated}}
  end

  defp response(_acc, _max, error), do: {:error, error}

  defp failure(%Mint.TransportError{reason: :timeout}), do: %{class: :timeout, reason: "timeout"}

  defp failure(%Mint.TransportError{reason: {:tls_alert, {alert, _text}}}) when is_atom(alert),
    do: %{class: :tls, reason: "tls_alert_" <> Atom.to_string(alert)}

  defp failure(%Mint.TransportError{reason: {:options, _option}}),
    do: %{class: :tls, reason: "tls_options"}

  defp failure(%Mint.TransportError{reason: reason}) when is_atom(reason),
    do: %{class: :connect, reason: Atom.to_string(reason)}

  defp failure(%Mint.TransportError{}), do: %{class: :connect, reason: "transport_error"}

  defp failure(%Mint.HTTPError{reason: {:proxy, _reason}}),
    do: %{class: :connect, reason: "proxy"}

  defp failure(%Mint.HTTPError{}), do: %{class: :protocol, reason: "http_error"}
end
