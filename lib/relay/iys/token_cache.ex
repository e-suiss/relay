defmodule Relay.Iys.TokenCache do
  @moduledoc """
  Node-local cache of İYS access tokens (PC-34). İYS limits the token endpoint by the hour and starts the hour again when it is asked too early, so a token is kept for the lifetime İYS gave it less a margin, its refresh token for its own lifetime, and a refused token request blocks the key for the time the caller names; nothing asks the token endpoint while a live token or a block is held.

  The values are held in this one process's state, never in ETS or `persistent_term` (TN-26 (3)), under a key that carries the tenant and the environment (TN-17). The password a token is derived from is never kept here. The cache holds at most `:max_entries` keys; when it is full the entry that ends soonest goes first. The process is sensitive and its status shows only the number of entries.
  """

  use GenServer

  alias Relay.Redacted

  @max_entries 1_024
  @margin_s 60
  @sweep_ms 60_000

  @derive {Inspect, only: [:max_entries]}
  defstruct entries: %{}, max_entries: @max_entries, sweep_ms: @sweep_ms
  use Relay.Hygiene, secret_fields: [:entries]

  @type key :: term()
  @type lookup ::
          {:ok, Redacted.t()} | {:refresh, Redacted.t()} | {:blocked, pos_integer()} | :miss

  @doc "Starts the cache; `:name`, `:max_entries` and `:sweep_ms` override the defaults."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  # PC-34
  @doc "What the cache holds for `key`: a live access token, a live refresh token to get one with, the seconds a block still lasts, or `:miss`. A cache that is not running is a miss."
  @spec lookup(GenServer.server(), key()) :: lookup()
  def lookup(server, key), do: call(server, {:lookup, key}, :miss)

  # PC-34
  @doc "Keeps the tokens of a token answer: `access` for `expires_in` seconds less the margin and `refresh`, when there is one, for `refresh_expires_in` seconds less the margin."
  @spec put(GenServer.server(), key(), Redacted.t(), integer(), Redacted.t() | nil, term()) :: :ok
  def put(server, key, access, expires_in, refresh, refresh_expires_in)
      when is_integer(expires_in) do
    lifetimes = {expires_in, refresh_expires_in}
    call(server, {:put, key, access, refresh, lifetimes}, :ok)
  end

  # PC-34
  @doc "Blocks `key` for `seconds`: until then `lookup/2` answers `{:blocked, left}`."
  @spec block(GenServer.server(), key(), pos_integer()) :: :ok
  def block(server, key, seconds) when is_integer(seconds) and seconds > 0,
    do: call(server, {:block, key, seconds}, :ok)

  @doc "Drops everything held for `key`."
  @spec drop(GenServer.server(), key()) :: :ok
  def drop(server, key), do: call(server, {:drop, key}, :ok)

  @doc "Returns the number of keys held."
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
  def handle_call({:lookup, key}, _from, state) do
    now = Relay.Clock.monotonic_ms()
    {:reply, found(Map.get(state.entries, key), now), state}
  end

  def handle_call({:put, key, access, refresh, {expires_in, refresh_expires_in}}, _from, state) do
    now = Relay.Clock.monotonic_ms()

    entry = %{
      access: access,
      access_until: now + ttl_ms(expires_in),
      refresh: refresh,
      refresh_until: now + ttl_ms(refresh_expires_in),
      blocked_until: nil
    }

    {:reply, :ok, %{state | entries: stored(state, key, entry, now)}}
  end

  def handle_call({:block, key, seconds}, _from, state) do
    now = Relay.Clock.monotonic_ms()

    entry = %{
      access: nil,
      access_until: nil,
      refresh: nil,
      refresh_until: nil,
      blocked_until: now + seconds * 1000
    }

    {:reply, :ok, %{state | entries: stored(state, key, entry, now)}}
  end

  def handle_call({:drop, key}, _from, state),
    do: {:reply, :ok, %{state | entries: Map.delete(state.entries, key)}}

  def handle_call(:size, _from, state), do: {:reply, map_size(state.entries), state}

  defp found(nil, _now), do: :miss

  defp found(%{blocked_until: until}, now) when is_integer(until) and until > now,
    do: {:blocked, div(until - now, 1000) + 1}

  defp found(%{access: access, access_until: until}, now)
       when access != nil and is_integer(until) and until > now,
       do: {:ok, access}

  defp found(%{refresh: refresh, refresh_until: until}, now)
       when refresh != nil and is_integer(until) and until > now,
       do: {:refresh, refresh}

  defp found(_expired, _now), do: :miss

  defp ttl_ms(seconds) when is_integer(seconds), do: max(seconds - @margin_s, 0) * 1000
  defp ttl_ms(_unknown), do: 0

  defp stored(state, key, entry, now) do
    state.entries
    |> Map.delete(key)
    |> room(now, state.max_entries)
    |> Map.put(key, entry)
  end

  defp room(entries, _now, max) when map_size(entries) < max, do: entries

  defp room(entries, now, max) do
    live = live(entries, now)
    if map_size(live) < max, do: live, else: evicted(live)
  end

  defp evicted(entries) when map_size(entries) == 0, do: entries

  defp evicted(entries) do
    {key, _entry} = Enum.min_by(entries, fn {_key, entry} -> ends(entry) end)
    Map.delete(entries, key)
  end

  defp live(entries, now), do: Map.filter(entries, fn {_key, entry} -> ends(entry) > now end)

  defp ends(entry) do
    [entry.access_until, entry.refresh_until, entry.blocked_until]
    |> Enum.filter(&is_integer/1)
    |> Enum.max()
  end

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
