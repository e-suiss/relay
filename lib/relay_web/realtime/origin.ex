defmodule RelayWeb.Realtime.Origin do
  @moduledoc """
  The browser origin of a WebSocket handshake (IN-54). The allowed origins belong to the tenant environment of the subscriber token, so the origin can only be decided after the token is checked. The socket's `check_origin` is therefore `{RelayWeb.Realtime.Origin, :record, []}`: Phoenix calls it, in the handshake's own process, only when the request carries an `Origin` header; it notes the origin and lets the handshake go on, and the transport takes the noted origin (`take/0`) before it checks the token, which then refuses an origin that is not on the list with `403 realtime_origin_not_allowed`. Origin checking is never turned off.

  An origin is written back as `scheme://host[:port]`, the port only when it is not the scheme's default; an origin that is not of that form (such as `null`) is kept as `null`, which no list holds.
  """

  @key {__MODULE__, :origin}

  # IN-54
  @doc "Notes the handshake's origin for the transport; always lets the handshake go on."
  @spec record(URI.t()) :: true
  def record(%URI{} = uri) do
    Process.put(@key, text(uri))
    true
  end

  # IN-54
  @doc "Takes the origin the handshake in this process noted, `nil` when it sent no `Origin` header."
  @spec take() :: String.t() | nil
  def take, do: Process.delete(@key)

  # IN-54
  @doc "An origin URI as its `Origin` header text, or `null` when it is not an origin."
  @spec text(URI.t()) :: String.t()
  def text(%URI{path: nil, query: nil, userinfo: nil, fragment: nil} = uri)
      when is_binary(uri.scheme) and is_binary(uri.host) and uri.host != "" do
    %URI{scheme: scheme, host: host, port: port} = uri

    if is_nil(port) or port == URI.default_port(scheme),
      do: scheme <> "://" <> host,
      else: scheme <> "://" <> host <> ":" <> Integer.to_string(port)
  end

  def text(%URI{}), do: "null"
end
