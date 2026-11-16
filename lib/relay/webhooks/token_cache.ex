defmodule Relay.Webhooks.TokenCache do
  @moduledoc """
  Node-local cache of the short-lived credentials destinations derive from their secret: the OAuth 2.0 access token of an HTTPS endpoint, the token of a service account, the credentials of an assumed role (WH-17, WH-19). They are held in this one process's state, never in ETS or `persistent_term` (TN-26 (3)), under a key that carries the tenant and the environment (TN-17).

  The cache is bounded twice. A value lives for the lifetime its issuer gave less a safety margin, and never longer than the caller's ceiling; a value without a lifetime is not kept at all. And the cache holds at most `:max_entries` values: when it is full the expired ones go first, then the one that expires soonest. A value an endpoint refused is dropped with `drop/2`, so the next attempt fetches a new one. The secret a value is derived from is never kept here.

  The process is sensitive and its status shows only the number of values it holds.
  """

  use GenServer

  alias Relay.Redacted

  @max_entries 1_024
  @margin_s 30
  @sweep_ms 60_000

  @derive {Inspect, only: [:max_entries]}
  defstruct entries: %{}, max_entries: @max_entries, sweep_ms: @sweep_ms
  use Relay.Hygiene, secret_fields: [:entries]

  @type key :: term()
  @type fetched :: {:ok, Redacted.t(), pos_integer() | nil} | {:error, map()}

  @doc "Starts the cache; `:max_entries` and `:sweep_ms` override the size and the one-minute sweep."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  # TN-17
  @doc "The cache key of an endpoint's derived credential: the scope, the endpoint, its row version and the secret reference it names, so a changed endpoint or a rotated secret never meets an old value."
  @spec key(Relay.Scope.t(), map()) :: key()
  def key(%Relay.Scope{} = scope, %{"id" => id} = endpoint) do
    {scope.tenant_id, scope.environment, id, endpoint["version"], endpoint["credential_ref_id"]}
  end

  # WH-19
  @doc "The value of `key`: the cached one while it lives, or the one `fetch` returns, which is kept for its lifetime less a margin and at most `max_ttl_s` seconds. A failed fetch is returned as it is and nothing is kept. `fetch` runs in the calling process."
  @spec through(GenServer.server(), key(), (-> fetched()), pos_integer()) ::
          {:ok, Redacted.t()} | {:error, map()}
  def through(server, key, fetch, max_ttl_s)
      when is_function(fetch, 0) and is_integer(max_ttl_s) and max_ttl_s > 0 do
    case fetch(server, key) do
      {:ok, value} -> {:ok, value}
      :miss -> fetched(server, key, fetch.(), max_ttl_s)
    end
  end

  defp fetched(server, key, {:ok, value, lifetime_s}, max_ttl_s) do
    :ok = put(server, key, value, ttl_s(lifetime_s, max_ttl_s))
    {:ok, value}
  end

  defp fetched(_server, _key, {:error, failure}, _max_ttl_s), do: {:error, failure}

  @doc "How long a value of `lifetime_s` seconds is kept: its lifetime less the margin, at most `max_ttl_s`, and not at all without a lifetime."
  @spec ttl_s(pos_integer() | nil, pos_integer()) :: non_neg_integer()
  def ttl_s(lifetime_s, max_ttl_s) when is_integer(lifetime_s),
    do: lifetime_s |> Kernel.-(@margin_s) |> min(max_ttl_s) |> max(0)

  def ttl_s(_unknown, _max_ttl_s), do: 0

  @doc "Returns a live cached value, or `:miss`; a cache that is not running is a miss."
  @spec fetch(GenServer.server(), key()) :: {:ok, Redacted.t()} | :miss
  def fetch(server, key), do: call(server, {:fetch, key}, :miss)

  @doc "Keeps `value` under `key` for `ttl_s` seconds; zero keeps nothing."
  @spec put(GenServer.server(), key(), Redacted.t(), non_neg_integer()) :: :ok
  def put(_server, _key, _value, 0), do: :ok

  def put(server, key, %Redacted{} = value, ttl_s) when is_integer(ttl_s) and ttl_s > 0,
    do: call(server, {:put, key, value, ttl_s * 1000}, :ok)

  # WH-19
  @doc "Drops the value of `key`."
  @spec drop(GenServer.server(), key()) :: :ok
  def drop(server, key), do: call(server, {:drop, key}, :ok)

  @doc "Returns the number of cached values."
  @spec size(GenServer.server()) :: non_neg_integer()
  def size(server), do: call(server, :size, 0)

  defp call(server, request, fallback) do
    GenServer.call(server, request)
  catch
    :exit, _reason -> fallback
  end

  @impl GenServer
  def init(opts) do
    Relay.Hygiene.sensitive!()

    state = %__MODULE__{
      max_entries: Keyword.get(opts, :max_entries, @max_entries),
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

  def handle_call({:put, key, value, ttl_ms}, _from, state) do
    now = Relay.Clock.monotonic_ms()

    entries =
      state.entries
      |> Map.delete(key)
      |> room(now, state.max_entries)
      |> Map.put(key, {value, now + ttl_ms})

    {:reply, :ok, %{state | entries: entries}}
  end

  def handle_call({:drop, key}, _from, state),
    do: {:reply, :ok, %{state | entries: Map.delete(state.entries, key)}}

  def handle_call(:size, _from, state), do: {:reply, map_size(state.entries), state}

  defp room(entries, _now, max) when map_size(entries) < max, do: entries

  defp room(entries, now, max) do
    live = live(entries, now)
    if map_size(live) < max, do: live, else: evicted(live)
  end

  defp evicted(entries) when map_size(entries) == 0, do: entries

  defp evicted(entries) do
    {key, _entry} = Enum.min_by(entries, fn {_key, {_value, expires_at}} -> expires_at end)
    Map.delete(entries, key)
  end

  defp live(entries, now),
    do: Map.reject(entries, fn {_key, {_value, expires_at}} -> expires_at <= now end)

  @impl GenServer
  def handle_info(:sweep, state) do
    schedule(state)
    {:noreply, %{state | entries: live(state.entries, Relay.Clock.monotonic_ms())}}
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
