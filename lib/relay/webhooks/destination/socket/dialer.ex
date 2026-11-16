defmodule Relay.Webhooks.Destination.Socket.Dialer do
  @moduledoc """
  The byte transport of a broker connection (WH-43). A dialer connects to the address it is given, never to an address it resolved itself: the host name is only the TLS server name and the name the server certificate is verified against. Production uses `Relay.Webhooks.Destination.Socket.Tls`; tests use a scripted dialer.
  """

  alias Relay.Webhooks.Egress.Transport

  @type handle :: term()
  @type connection :: %{
          address: :inet.ip_address(),
          host: String.t(),
          port: :inet.port_number(),
          mode: :tls | :plain,
          connect_timeout_ms: pos_integer(),
          client_certificate: Transport.client_certificate() | nil,
          ca_certificates: [binary(), ...] | nil
        }
  @type error :: %{class: :connect | :timeout | :tls, reason: String.t()}

  @doc "Opens a connection to `connection.address`: TLS, or TCP alone when the mode is `:plain`."
  @callback connect(connection()) :: {:ok, handle()} | {:error, error()}

  @doc "Starts TLS on a connection opened in `:plain` mode."
  @callback upgrade(handle(), connection()) :: {:ok, handle()} | {:error, error()}

  @doc "Writes to the connection."
  @callback write(handle(), iodata()) :: :ok | {:error, error()}

  @doc "Reads exactly `length` bytes, or what has arrived when `length` is 0, within `timeout_ms`."
  @callback read(handle(), length :: non_neg_integer(), timeout_ms :: pos_integer()) ::
              {:ok, binary()} | {:error, error()}

  @doc "Closes the connection."
  @callback close(handle()) :: :ok
end
