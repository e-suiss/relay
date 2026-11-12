defmodule RelayWeb.Realtime.Transport do
  @moduledoc """
  The WebSocket transport in front of `RelayWeb.Realtime.Socket` (IN-23, IN-52). It takes every new connection from the node's accept rate (`Relay.Realtime.admit/0`) before the token is checked; a connection over the rate is upgraded and closed at once with code `1013` and a reason `retry-after=<seconds>`, the seconds jittered over the contract's range. A connection the socket refuses gets the HTTP problem of the refusal instead of an upgrade. The channel closes its transport with a code and a reason when the authorization is withdrawn, the token expires or newer connections push it out (`RelayWeb.Realtime.Session.close_code/1`). Everything else is the Phoenix socket's own handling.
  """

  @behaviour Phoenix.Socket.Transport

  alias RelayWeb.Api.Response
  alias RelayWeb.Realtime.Socket

  @impl true
  def child_spec(opts), do: Socket.child_spec(opts)

  @impl true
  def drainer_spec(opts), do: Socket.drainer_spec(opts)

  # IN-34
  # IN-52
  @impl true
  def connect(map) do
    case Relay.Realtime.admit() do
      :ok -> wrap(Socket.connect(map))
      {:error, retry_after} -> {:ok, {:overloaded, retry_after}}
    end
  end

  @impl true
  def init({:overloaded, _retry_after} = state) do
    send(self(), :relay_realtime_overloaded)
    {:ok, state}
  end

  def init({:socket, state}), do: wrap(Socket.init(state))

  @impl true
  def handle_in(_message, {:overloaded, _retry_after} = state), do: {:ok, state}
  def handle_in(message, {:socket, state}), do: wrap(Socket.handle_in(message, state))

  @impl true
  def handle_info(:relay_realtime_overloaded, {:overloaded, retry_after} = state),
    do: {:stop, :normal, {1013, "retry-after=#{retry_after}"}, state}

  def handle_info({:relay_realtime_close, code, reason}, {:socket, _state} = state),
    do: {:stop, {:shutdown, :closed}, {code, reason}, state}

  def handle_info(_message, {:overloaded, _retry_after} = state), do: {:ok, state}
  def handle_info(message, {:socket, state}), do: wrap(Socket.handle_info(message, state))

  @impl true
  def terminate(_reason, {:overloaded, _retry_after}), do: :ok
  def terminate(reason, {:socket, state}), do: Socket.terminate(reason, state)

  # IN-33
  # sobelow_skip ["XSS.SendResp"]
  @doc "Answers a refused WebSocket connection with the problem of its error."
  @spec handle_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def handle_error(conn, %Relay.Error{} = error), do: Response.problem(conn, error)

  def handle_error(conn, _reason),
    do: Response.problem(conn, Relay.Error.new(:auth_invalid_token, "connection refused"))

  defp wrap({:ok, state}), do: {:ok, {:socket, state}}
  defp wrap({:push, data, state}), do: {:push, data, {:socket, state}}
  defp wrap({:reply, status, data, state}), do: {:reply, status, data, {:socket, state}}
  defp wrap({:stop, reason, state}), do: {:stop, reason, {:socket, state}}
  defp wrap({:stop, reason, close, state}), do: {:stop, reason, close, {:socket, state}}
  defp wrap({:error, _reason} = error), do: error
  defp wrap(:error), do: :error
end
