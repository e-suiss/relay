defmodule Relay.Tenancy.KeyCache do
  @moduledoc """
  Node-local cache of unwrapped data keys, held in this one process's state for ten minutes; never in ETS or `persistent_term`. A flush drops every key and starts a new generation: a key read from the database before a flush is refused when it is put back after it, so a destruction signal can never be outrun by a slow unwrap. The process is sensitive and its status shows only the number of keys it holds.
  """

  use GenServer

  @ttl_ms 10 * 60_000
  @sweep_ms 60_000

  @derive {Inspect, only: [:generation, :ttl_ms]}
  defstruct entries: %{}, generation: 0, ttl_ms: @ttl_ms, sweep_ms: @sweep_ms
  use Relay.Hygiene, secret_fields: [:entries]

  @type key :: term()
  @type generation :: non_neg_integer()

  @doc "Starts the cache; `:ttl_ms` and `:sweep_ms` override the ten-minute lifetime and the one-minute sweep."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  # TN-27
  # TN-66 (2)
  @doc "Returns a live cached key, or `:miss`; a cache that is not running is a miss."
  @spec fetch(GenServer.server(), key()) :: {:ok, Relay.Redacted.t()} | :miss
  def fetch(server \\ __MODULE__, key), do: call(server, {:fetch, key}, :miss)

  @doc "Returns the current generation; read it before reading the key from the database."
  @spec generation(GenServer.server()) :: generation() | nil
  def generation(server \\ __MODULE__), do: call(server, :generation, nil)

  @doc "Caches a key read during `generation`; a key from an earlier generation is refused."
  @spec put(GenServer.server(), key(), Relay.Redacted.t(), generation() | nil) :: :ok | :stale
  def put(server \\ __MODULE__, key, value, generation),
    do: call(server, {:put, key, value, generation}, :stale)

  # TN-66 (2)
  # OP-17
  @doc "Drops every cached key and starts a new generation."
  @spec flush(GenServer.server()) :: :ok
  def flush(server \\ __MODULE__), do: call(server, :flush, :ok)

  @doc "Returns the number of cached keys."
  @spec size(GenServer.server()) :: non_neg_integer()
  def size(server \\ __MODULE__), do: call(server, :size, 0)

  defp call(server, request, fallback) do
    GenServer.call(server, request)
  catch
    :exit, _reason -> fallback
  end

  @impl GenServer
  def init(opts) do
    Relay.Hygiene.sensitive!()

    state = %__MODULE__{
      ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms),
      sweep_ms: Keyword.get(opts, :sweep_ms, @sweep_ms)
    }

    schedule(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:fetch, key}, _from, state) do
    now = Relay.Clock.monotonic_ms()

    case Map.fetch(state.entries, key) do
      {:ok, {value, expires_at}} when expires_at > now ->
        {:reply, {:ok, value}, state}

      {:ok, _expired} ->
        {:reply, :miss, %{state | entries: Map.delete(state.entries, key)}}

      :error ->
        {:reply, :miss, state}
    end
  end

  def handle_call(:generation, _from, state), do: {:reply, state.generation, state}

  def handle_call({:put, key, value, generation}, _from, %{generation: generation} = state) do
    entry = {value, Relay.Clock.monotonic_ms() + state.ttl_ms}
    {:reply, :ok, %{state | entries: Map.put(state.entries, key, entry)}}
  end

  def handle_call({:put, _key, _value, _generation}, _from, state),
    do: {:reply, :stale, state}

  def handle_call(:flush, _from, state),
    do: {:reply, :ok, %{state | entries: %{}, generation: state.generation + 1}}

  def handle_call(:size, _from, state), do: {:reply, map_size(state.entries), state}

  @impl GenServer
  def handle_info(:sweep, state) do
    now = Relay.Clock.monotonic_ms()
    entries = Map.reject(state.entries, fn {_key, {_value, expires_at}} -> expires_at <= now end)
    schedule(state)
    {:noreply, %{state | entries: entries}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # T-46
  @impl GenServer
  def format_status(status) do
    Relay.Hygiene.format_status(status, fn
      %__MODULE__{} = state -> %{state | entries: map_size(state.entries)}
      other -> other
    end)
  end

  defp schedule(state), do: Process.send_after(self(), :sweep, state.sweep_ms)
end
