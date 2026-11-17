defmodule RelayWeb.Api.Capture do
  @moduledoc """
  A connection adapter that keeps a response instead of writing it to a socket. `RelayWeb.Api.McpController` runs the controller of a tool's operation on a connection with this adapter and reads the status and the body the operation answered (AG-43, E-52). It has no request body and supports no streaming, upgrade or informational response.
  """

  @behaviour Plug.Conn.Adapter

  @impl Plug.Conn.Adapter
  def send_resp(state, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), state}

  @impl Plug.Conn.Adapter
  def send_file(state, _status, _headers, _path, _offset, _length), do: {:ok, "", state}

  @impl Plug.Conn.Adapter
  def send_chunked(state, _status, _headers), do: {:ok, "", state}

  @impl Plug.Conn.Adapter
  def chunk(_state, _body), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def read_req_body(state, _opts), do: {:ok, "", state}

  @impl Plug.Conn.Adapter
  def inform(_state, _status, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def upgrade(_state, _protocol, _opts), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def push(_state, _path, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def get_peer_data(_state), do: %{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil}

  @impl Plug.Conn.Adapter
  def get_http_protocol(_state), do: :"HTTP/1.1"
end
