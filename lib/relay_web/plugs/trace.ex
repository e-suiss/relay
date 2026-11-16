defmodule RelayWeb.Plugs.Trace do
  @moduledoc """
  The server span of a request: a valid incoming `traceparent` is continued, otherwise the request starts a trace; the request's context becomes the process's current context, so log lines and the records the request writes carry it, and the span is recorded when the response is sent, named by the API operation, or by the method when there is none.
  """

  @behaviour Plug

  # E-72
  # OP-34
  # T-63 (2)
  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    parent =
      case Plug.Conn.get_req_header(conn, "traceparent") do
        [value | _] -> if Relay.Trace.valid?(value), do: value
        [] -> nil
      end

    traceparent = Relay.Trace.child(parent)
    :ok = Relay.Trace.put(traceparent)
    started_at = Relay.Clock.utc_now()

    Plug.Conn.register_before_send(conn, &finish(&1, traceparent, parent, started_at))
  end

  defp finish(conn, traceparent, parent, started_at) do
    operation = conn.private[:relay_operation]

    Relay.Trace.record(%{
      name: operation || conn.method,
      kind: :server,
      traceparent: traceparent,
      parent_span_id: Relay.Trace.span_id(parent),
      started_at: started_at,
      ended_at: Relay.Clock.utc_now(),
      attributes: %{
        "http.request.method" => conn.method,
        "http.response.status_code" => conn.status,
        "relay.operation" => operation
      },
      links: [],
      error?: is_integer(conn.status) and conn.status >= 500
    })

    conn
  end
end
