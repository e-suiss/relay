defmodule RelayTest.ScriptedSocket do
  @moduledoc """
  A scripted dialer for broker destination tests, with no network at all. A test registers one server per host name with `serve/3`; the server is a function that is given `:open`, `:upgrade` or `{:data, bytes}` and its state, and returns the bytes it answers with and its next state. Everything runs in the test process: the connection a destination asked for arrives as `{:dialed, connection}`, an upgrade as `{:upgraded, host}`, and the end of a connection as `{:closed, host}`.

  `refuse/2` makes the connection to a host fail with the given error.
  """

  use Boundary, top_level?: true, check: [out: false]

  @behaviour Relay.Webhooks.Destination.Socket.Dialer

  @type event :: :open | :upgrade | {:data, binary()}
  @type server :: (event(), term() -> {iodata(), term()})

  @doc "Registers the server of `host` with its first state."
  @spec serve(String.t(), server(), term()) :: :ok
  def serve(host, server, state \\ nil) when is_binary(host) and is_function(server, 2) do
    Process.put({__MODULE__, :server, host}, {server, state})
    :ok
  end

  @doc "Makes every connection to `host` fail with `error`."
  @spec refuse(String.t(), map()) :: :ok
  def refuse(host, error) when is_binary(host) and is_map(error) do
    Process.put({__MODULE__, :refused, host}, error)
    :ok
  end

  @impl Relay.Webhooks.Destination.Socket.Dialer
  def connect(connection) do
    send(self(), {:dialed, connection})

    case Process.get({__MODULE__, :refused, connection.host}) do
      nil -> open(connection.host)
      error -> {:error, error}
    end
  end

  defp open(host) do
    case Process.get({__MODULE__, :server, host}) do
      nil ->
        {:error, %{class: :connect, reason: "econnrefused"}}

      {server, state} ->
        handle = {host, make_ref()}
        Process.put({__MODULE__, handle}, %{server: server, state: state, inbox: ""})
        feed(handle, :open)
        {:ok, handle}
    end
  end

  @impl Relay.Webhooks.Destination.Socket.Dialer
  def upgrade({host, _ref} = handle, _connection) do
    send(self(), {:upgraded, host})
    feed(handle, :upgrade)
    {:ok, handle}
  end

  @impl Relay.Webhooks.Destination.Socket.Dialer
  def write(handle, data) do
    feed(handle, {:data, IO.iodata_to_binary(data)})
    :ok
  end

  @impl Relay.Webhooks.Destination.Socket.Dialer
  def read(handle, length, _timeout_ms) do
    %{inbox: inbox} = connection = Process.get({__MODULE__, handle})

    cond do
      inbox == "" or byte_size(inbox) < length ->
        {:error, %{class: :timeout, reason: "timeout"}}

      length == 0 ->
        Process.put({__MODULE__, handle}, %{connection | inbox: ""})
        {:ok, inbox}

      true ->
        rest = binary_part(inbox, length, byte_size(inbox) - length)
        Process.put({__MODULE__, handle}, %{connection | inbox: rest})
        {:ok, binary_part(inbox, 0, length)}
    end
  end

  @impl Relay.Webhooks.Destination.Socket.Dialer
  def close({host, _ref}) do
    send(self(), {:closed, host})
    :ok
  end

  defp feed(handle, event) do
    %{server: server, state: state, inbox: inbox} = Process.get({__MODULE__, handle})
    {answer, state} = server.(event, state)
    inbox = inbox <> IO.iodata_to_binary(answer)
    Process.put({__MODULE__, handle}, %{server: server, state: state, inbox: inbox})
    :ok
  end
end
