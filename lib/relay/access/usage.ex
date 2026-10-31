defmodule Relay.Access.Usage do
  @moduledoc """
  Last use of API clients (`last_used_at`, `last_used_ip`; API-44, S-73). A verified request only notes its client here; the process writes each noted client at most once a minute, in a short transaction of its own per client and never on the request path, and the database function throttles the same way across nodes. A failed write is dropped: it never affects a request.
  """

  use GenServer

  @flush_ms 5_000
  @every_ms 60_000

  @doc "Starts the usage writer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # API-44
  @doc "Notes a use of an API client from a client address."
  @spec note(Relay.Scope.t(), Relay.Id.t(), :inet.ip_address() | nil) :: :ok
  def note(%Relay.Scope{} = scope, <<_::128>> = api_client_id, ip) do
    GenServer.cast(__MODULE__, {:note, scope, api_client_id, ip})
  end

  # API-44
  @doc "Writes the noted uses now; returns how many were written."
  @spec flush() :: non_neg_integer()
  def flush, do: GenServer.call(__MODULE__, :flush, 30_000)

  @impl GenServer
  def init(_opts) do
    Process.send_after(self(), :flush, @flush_ms)
    {:ok, %{pending: %{}, written: %{}}}
  end

  @impl GenServer
  def handle_cast({:note, scope, id, ip}, state) do
    now = Relay.Clock.monotonic_ms()

    case Map.get(state.written, id) do
      at when is_integer(at) and now - at < @every_ms -> {:noreply, state}
      _never_or_due -> {:noreply, %{state | pending: Map.put(state.pending, id, {scope, ip})}}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    {count, state} = write(state)
    {:reply, count, state}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    {_count, state} = write(state)
    Process.send_after(self(), :flush, @flush_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp write(%{pending: pending} = state) when map_size(pending) == 0, do: {0, state}

  defp write(state) do
    now = Relay.Clock.monotonic_ms()
    written = Enum.count(state.pending, &touch/1)

    stamped = Map.new(state.pending, fn {id, _value} -> {id, now} end)
    recent = Map.reject(state.written, fn {_id, at} -> now - at >= @every_ms end)
    {written, %{state | pending: %{}, written: Map.merge(recent, stamped)}}
  end

  defp touch({id, {scope, ip}}), do: Relay.Access.touch(scope, id, ip)
end
