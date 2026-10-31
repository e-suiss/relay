defmodule Relay.Access.Link do
  @moduledoc """
  The node's view of the Access link (E-40, E-78). PostgreSQL holds the durable cache (`relay.access_link`); this process owns an ETS table with the snapshot every request reads: the link state, the usable Access keys and the endpoints of discovery. A node starts without waiting for Access (E-5, E-75): before the first successful fetch the state is `:pending` and token verification answers `service_unavailable`.

  `refresh/1` fetches the discovery documents and the key set, outside any transaction, writes the result through `relay_ops.access_link_store` and signals `relay:s:signal:access_link`; every node re-reads the row on the signal, on a re-read tick and every 30 seconds. A failed fetch keeps the last key set: the state becomes `:stale`, verification goes on and the state is visible in telemetry and the log. A link whose Access names another region is `:region_mismatch` and holds no keys (INV-41, TN-57). An unknown `kid` asks for an early refresh, at most once every 30 seconds (S-68).

  With `config :relay, Relay.Access, autoload: false` the process neither reads the row nor subscribes by itself.

  Telemetry: `[:relay, :access, :link]` (`down`: 1 while the link is not `:ok`) with the `state` and the store `result`; it feeds the `relay_access_link_down` alarm.
  """

  use GenServer

  require Logger

  alias Relay.Access.Discovery
  alias Relay.Access.Http
  alias Relay.Access.Jose
  alias Relay.Access.LinkStore

  @table __MODULE__
  @reload_ms 30_000
  @early_refresh_ms 30_000
  @states %{
    "ok" => :ok,
    "stale" => :stale,
    "pending" => :pending,
    "region_mismatch" => :region_mismatch
  }

  @type state :: :ok | :stale | :pending | :region_mismatch
  @type snapshot :: %{
          state: state(),
          issuer: String.t() | nil,
          keys: [Jose.key()],
          region: String.t() | nil,
          token_endpoint: String.t() | nil,
          management_api: String.t() | nil,
          event_subscriptions: String.t() | nil
        }

  @doc "Starts the process that owns the link snapshot."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Signal topic of link writes."
  @spec topic() :: String.t()
  def topic, do: Relay.Platform.system_signal_topic(["access_link"])

  # E-75
  @doc "The node's current link snapshot, or `:unknown` while the process is not running."
  @spec current() :: snapshot() | :unknown
  def current do
    case :ets.lookup(@table, :snapshot) do
      [{:snapshot, snapshot}] -> snapshot
      [] -> :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  @doc "Publishes a snapshot on this node."
  @spec put(snapshot()) :: :ok
  def put(snapshot), do: GenServer.call(__MODULE__, {:put, snapshot})

  # E-75
  @doc "Re-reads the link row and publishes its snapshot on this node."
  @spec reload() :: {:ok, snapshot()}
  def reload do
    snapshot = load()
    :ok = put(snapshot)
    {:ok, snapshot}
  end

  # E-5
  # E-40
  # E-75
  # E-78
  # INV-41
  # INV-55
  @doc "Fetches the discovery documents and the key set of the configured issuer, records the result, signals the other nodes and reloads this one. Options: `:http`, extra `Req` options."
  @spec refresh(keyword()) :: {:ok, state()} | {:error, Relay.Error.t()}
  def refresh(opts \\ []) do
    case Relay.Access.issuer() do
      nil ->
        {:error, Relay.Error.new(:access_not_configured, "no Access issuer is configured")}

      issuer ->
        http = Keyword.get(opts, :http, [])
        fetched = fetch(issuer, http)
        result = LinkStore.store(attrs(issuer, fetched))
        _ = Relay.Platform.publish_signal(topic(), DateTime.to_unix(Relay.Clock.utc_now()))
        {:ok, snapshot} = reload()
        report(snapshot, result, fetched)
    end
  end

  # E-75
  @doc "Refreshes the link early because a token names an unknown key; at most once every 30 seconds per node."
  @spec refresh_keys(keyword()) :: {:ok, state()} | {:error, Relay.Error.t()} | :throttled
  def refresh_keys(opts \\ []) do
    if GenServer.call(__MODULE__, :claim_refresh), do: refresh(opts), else: :throttled
  end

  defp fetch(issuer, http) do
    with {:ok, document, raw} <- Http.get_json(Discovery.openid_url(issuer), http),
         {:ok, parsed} <- Discovery.parse(document, issuer),
         {:ok, jwks, jwks_raw} <- Http.get_json(parsed.jwks_uri, http),
         {:ok, _keys, public} <- Jose.public_keys(jwks) do
      {:ok,
       %{
         document: document,
         digest: :crypto.hash(:sha256, raw),
         parsed: parsed,
         jwks: public,
         jwks_digest: :crypto.hash(:sha256, jwks_raw),
         authzen: authzen(issuer, http)
       }}
    end
  end

  defp authzen(issuer, http) do
    case Http.get_json(Discovery.authzen_url(issuer), http) do
      {:ok, document, raw} when byte_size(raw) <= 15_000 -> document
      _ -> nil
    end
  end

  defp attrs(issuer, {:ok, fetched}) do
    %{
      issuer: issuer,
      discovery: fetched.document,
      authzen: fetched.authzen,
      jwks: fetched.jwks,
      discovery_digest: fetched.digest,
      jwks_digest: fetched.jwks_digest,
      region: fetched.parsed.region,
      management_api: fetched.parsed.management_api,
      event_subscriptions: fetched.parsed.event_subscriptions
    }
  end

  defp attrs(issuer, {:error, _error}) do
    %{
      issuer: issuer,
      discovery: nil,
      authzen: nil,
      jwks: nil,
      discovery_digest: nil,
      jwks_digest: nil,
      region: nil,
      management_api: nil,
      event_subscriptions: nil
    }
  end

  defp report(snapshot, result, fetched) do
    :telemetry.execute(
      [:relay, :access, :link],
      %{down: if(snapshot.state == :ok, do: 0, else: 1)},
      %{state: snapshot.state, result: result}
    )

    case {snapshot.state, fetched} do
      {:ok, _fetched} ->
        {:ok, :ok}

      {:region_mismatch, _fetched} ->
        Logger.error("Access link refused: Access serves another region", result: result)
        {:error, Relay.Error.new(:access_region_mismatch, "Access serves another region")}

      {state, {:error, error}} ->
        Logger.warning("Access link not refreshed", state: state, code: error.code)
        {:error, error}

      {state, {:ok, _fetched}} ->
        Logger.warning("Access link not established", state: state, result: result)
        {:error, Relay.Error.new(:access_unreachable, "the Access link is #{state}")}
    end
  end

  defp load, do: snapshot(LinkStore.read(), Relay.Access.issuer())

  @doc "Builds the snapshot of a stored link row for the configured issuer; a row of another issuer counts as no row."
  @spec snapshot(LinkStore.row() | nil, String.t() | nil) :: snapshot()
  def snapshot(%{issuer: issuer} = row, issuer) when is_binary(issuer) do
    parsed =
      case row.discovery && Discovery.parse(row.discovery, issuer) do
        {:ok, parsed} -> parsed
        _ -> %{token_endpoint: nil}
      end

    %{
      state: Map.fetch!(@states, row.state),
      issuer: issuer,
      keys: keys(row.jwks),
      region: row.access_region,
      token_endpoint: parsed.token_endpoint,
      management_api: row.management_api,
      event_subscriptions: row.event_subscriptions
    }
  end

  def snapshot(_row, issuer) do
    %{
      state: :pending,
      issuer: issuer,
      keys: [],
      region: nil,
      token_endpoint: nil,
      management_api: nil,
      event_subscriptions: nil
    }
  end

  defp keys(nil), do: []

  defp keys(jwks) do
    case Jose.public_keys(jwks) do
      {:ok, keys, _public} -> keys
      {:error, _error} -> []
    end
  end

  @impl GenServer
  def init(opts) do
    _ = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    autoload = Keyword.get(opts, :autoload, Keyword.get(Relay.Access.config(), :autoload, true))
    :ets.insert(@table, {:snapshot, snapshot(nil, Relay.Access.issuer())})

    if autoload do
      _ = Relay.Platform.subscribe_signal(topic())
      send(self(), :reload)
    end

    {:ok, %{autoload: autoload, refreshed_ms: nil}}
  end

  @impl GenServer
  def handle_call({:put, snapshot}, _from, state) do
    :ets.insert(@table, {:snapshot, snapshot})
    {:reply, :ok, state}
  end

  def handle_call(:claim_refresh, _from, state) do
    now = Relay.Clock.monotonic_ms()

    if is_nil(state.refreshed_ms) or now - state.refreshed_ms >= @early_refresh_ms,
      do: {:reply, true, %{state | refreshed_ms: now}},
      else: {:reply, false, state}
  end

  @impl GenServer
  def handle_info(:reload, state) do
    safe_reload()
    Process.send_after(self(), :reload, @reload_ms)
    {:noreply, state}
  end

  def handle_info({:relay_signal, _topic, _event}, state) do
    safe_reload()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp safe_reload do
    :ets.insert(@table, {:snapshot, load()})
  rescue
    exception ->
      Logger.warning("Access link not read; the last snapshot stays",
        error: Exception.message(exception)
      )
  end
end
