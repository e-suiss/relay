defmodule Relay.Webhooks.Egress.Transport do
  @moduledoc """
  The HTTP port of the egress boundary (WH-41 (1), WH-42 (3)). A transport sends one request over a new TLS connection to the address it is given, never to an address it resolved itself: the host name is used only as SNI, as the `Host` header and as the name the server certificate is verified against. It never follows a redirect, keeps no connection for another request and reads at most `max_response_bytes` of the response body. Production uses `Relay.Webhooks.Egress.Transport.Pinned`; tests use a fake transport.
  """

  @type client_certificate :: %{
          required(:certificate) => binary() | [binary(), ...],
          required(:key) => Relay.Redacted.t()
        }
  @type proxy :: {:http | :https, String.t(), :inet.port_number()}
  @type connection :: %{
          address: :inet.ip_address(),
          host: String.t(),
          port: :inet.port_number(),
          connect_timeout_ms: pos_integer(),
          total_timeout_ms: pos_integer(),
          max_response_bytes: non_neg_integer(),
          client_certificate: client_certificate() | nil,
          ca_certificates: [binary(), ...] | nil,
          proxy: proxy() | nil
        }
  @type request :: %{
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: iodata()
        }
  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          truncated: boolean()
        }
  @type error :: %{class: :connect | :timeout | :tls | :protocol, reason: String.t()}

  @doc "Sends `request` to `connection.address` and returns the response head and at most `max_response_bytes` of its body."
  @callback request(connection(), request()) :: {:ok, response()} | {:error, error()}
end
