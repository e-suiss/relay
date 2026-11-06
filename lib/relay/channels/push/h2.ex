defmodule Relay.Channels.Push.H2 do
  @moduledoc """
  Relay's own thin HTTP/2 client for APNs and FCM HTTP v1, on Mint (CH-24, T-37, INV-40). One connection process (`Relay.Channels.Push.H2.Connection`) serves one key, and a key is one tenant environment, one provider, one origin (the APNs production or sandbox host, the FCM host) and one credential (the APNs team and key, the Firebase project): requests carrying different tenants' tokens never share a connection.

  A connection opens lazily on its first request through `Relay.TenantWorker` and stops when idle (T-45 (6)). Admission control is per connection: a semaphore admits at most the server's `SETTINGS_MAX_CONCURRENT_STREAMS` (capped) streams and, until the server's SETTINGS have arrived, a single one, so a cold connection never carries concurrent requests; the rest wait in a bounded queue, and a request that finds the queue full is refused with `too_many_concurrent_requests`, a `transient` failure. Connections are pinged, renewed after a jittered maximum age and drained after a GOAWAY; requests the server did not process come back as never sent.

  The result of `request/7`: `{:ok, response}`, `{:not_sent, reason}` when the request never reached the provider (a retry is safe) or `{:uncertain, reason}` when it may have (T-28). The client never retries and never follows redirects; TLS peer verification cannot be turned off (T-43).
  """

  alias Relay.Channels.Push.H2.Connection

  @type origin :: {:http | :https, String.t(), :inet.port_number()}
  @type key :: term()

  @typedoc "The `authorization` source of a connection: a `Relay.Channels.Push.H2.Auth` module and its configuration, or `nil`."
  @type auth :: {module(), term()} | nil

  @type request :: %{
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @type response :: %{
          status: pos_integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @type result :: {:ok, response()} | {:not_sent, String.t()} | {:uncertain, String.t()}

  # CH-24
  # T-37
  # INV-40
  @doc """
  Sends one request on the connection of `key` in the tenant `tenant_id` to `origin`, opening it when needed, and waits at most `timeout_ms`. `opts` are the connection options (see `Relay.Channels.Push.H2.Connection`), read when the connection opens.
  """
  @spec request(Relay.Id.t(), key(), origin(), auth(), request(), pos_integer(), keyword()) ::
          result()
  def request(tenant_id, key, origin, auth, %{} = request, timeout_ms, opts \\ [])
      when is_integer(timeout_ms) and timeout_ms > 0 do
    :ok = Relay.NetworkGuard.check!(:http)
    opts = Keyword.merge([idle_ms: Connection.idle_ms()], opts)
    args = [key: key, origin: origin, opts: opts, idle_ms: Keyword.fetch!(opts, :idle_ms)]

    case Relay.TenantWorker.ensure(tenant_id, {__MODULE__, key}, {Connection, args}) do
      {:ok, pid} -> call(pid, key, auth, request, timeout_ms)
      {:error, _reason} -> {:not_sent, "connection_unavailable"}
    end
  end

  defp call(pid, key, auth, request, timeout_ms) do
    deadline = Relay.Clock.monotonic_ms() + timeout_ms
    GenServer.call(pid, {:request, key, auth, request, deadline}, timeout_ms + 1_000)
  catch
    :exit, _reason -> {:uncertain, "connection_exited"}
  end

  @doc "The connection process of a key in a tenant, if one is open."
  @spec whereis(Relay.Id.t(), key()) :: pid() | nil
  def whereis(tenant_id, key), do: Relay.TenantWorker.whereis(tenant_id, {__MODULE__, key})
end
