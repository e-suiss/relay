defmodule Relay.Webhooks.Destination.Socket.Tls do
  @moduledoc """
  The production dialer of broker connections, on `:ssl` and `:gen_tcp` (WH-41 (1), WH-43).

  The connection is opened to the validated IP address. The original host name is the server name indication and the name the certificate is verified against, with the operating system's CA store unless the caller gives its own; a destination given as an IP address is verified against that address. Nothing is resolved here. The connection and the TLS handshake are bounded by the connect timeout.
  """

  @behaviour Relay.Webhooks.Destination.Socket.Dialer

  alias Relay.Redacted
  alias Relay.Webhooks.Egress.Address

  @tcp [:binary, active: false, packet: :raw, nodelay: true]

  # WH-41 (1)
  @impl Relay.Webhooks.Destination.Socket.Dialer
  def connect(%{mode: :plain} = connection) do
    options = @tcp ++ family(connection.address)
    timeout = connection.connect_timeout_ms

    case :gen_tcp.connect(connection.address, connection.port, options, timeout) do
      {:ok, socket} -> {:ok, {:tcp, socket}}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  def connect(%{mode: :tls} = connection) do
    options = @tcp ++ family(connection.address) ++ tls(connection)
    timeout = connection.connect_timeout_ms

    case :ssl.connect(connection.address, connection.port, options, timeout) do
      {:ok, socket} -> {:ok, {:tls, socket}}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl Relay.Webhooks.Destination.Socket.Dialer
  def upgrade({:tcp, socket}, connection) do
    case :ssl.connect(socket, tls(connection), connection.connect_timeout_ms) do
      {:ok, upgraded} -> {:ok, {:tls, upgraded}}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  def upgrade({:tls, _socket} = handle, _connection), do: {:ok, handle}

  @impl Relay.Webhooks.Destination.Socket.Dialer
  def write({:tcp, socket}, data), do: written(:gen_tcp.send(socket, data))
  def write({:tls, socket}, data), do: written(:ssl.send(socket, data))

  defp written(:ok), do: :ok
  defp written({:error, reason}), do: {:error, failure(reason)}

  @impl Relay.Webhooks.Destination.Socket.Dialer
  def read({:tcp, socket}, length, timeout_ms),
    do: received(:gen_tcp.recv(socket, length, timeout_ms))

  def read({:tls, socket}, length, timeout_ms),
    do: received(:ssl.recv(socket, length, timeout_ms))

  defp received({:ok, data}), do: {:ok, data}
  defp received({:error, reason}), do: {:error, failure(reason)}

  @impl Relay.Webhooks.Destination.Socket.Dialer
  def close({:tcp, socket}), do: :gen_tcp.close(socket)

  def close({:tls, socket}) do
    _closed = :ssl.close(socket)
    :ok
  end

  defp family(address) when tuple_size(address) == 8, do: [:inet6]
  defp family(_address), do: [:inet]

  defp tls(connection) do
    match = :public_key.pkix_verify_hostname_match_fun(:https)

    [verify: :verify_peer, customize_hostname_check: [match_fun: match]]
    |> server_name(connection.host)
    |> trust(connection.ca_certificates)
    |> identity(connection.client_certificate)
  end

  defp server_name(options, host) do
    case Address.parse(host) do
      {:ok, _ip} -> options
      :error -> options ++ [server_name_indication: String.to_charlist(host)]
    end
  end

  defp trust(options, nil), do: options ++ [cacerts: :public_key.cacerts_get()]
  defp trust(options, certificates), do: options ++ [cacerts: certificates]

  defp identity(options, nil), do: options

  defp identity(options, %{certificate: certificate, key: key}),
    do: options ++ [cert: certificate, key: Redacted.expose(key)]

  defp failure(:timeout), do: %{class: :timeout, reason: "timeout"}

  defp failure({:tls_alert, {alert, _text}}) when is_atom(alert),
    do: %{class: :tls, reason: "tls_alert_" <> Atom.to_string(alert)}

  defp failure({:options, _option}), do: %{class: :tls, reason: "tls_options"}

  defp failure(reason) when is_atom(reason),
    do: %{class: :connect, reason: Atom.to_string(reason)}

  defp failure(_reason), do: %{class: :connect, reason: "transport_error"}
end
