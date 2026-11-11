defmodule Relay.Observability.TopTenants do
  @moduledoc """
  The counting window behind the bounded tenant label and the noisy neighbour shares. Jobs processed are counted per tenant and per queue, accepted API requests per API client, in one protected ETS table that only this process writes; the telemetry handlers send it the counts, and its mailbox lives off the heap. Every minute the window closes: the busiest tenants of the window (POLICY DEFAULT 20) keep their own label until the next close, every other tenant is `other`; the largest tenant share of each queue's processed jobs and the largest API client share of requests are emitted as `[:relay, :neighbours, :share]` with `%{share}` and `%{signal, queue}`, when the window saw at least 100 of them; then the window starts again. Tenant and client identifiers never leave this table except as the label of the busiest tenants.
  """

  use GenServer

  alias Relay.Observability.Handlers

  @counts __MODULE__.Counts
  @top __MODULE__.Top
  @size 20
  @min_volume 100
  @window_ms 60_000

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # OP-35 (3)
  @doc "The number of tenants that keep their own label."
  @spec size() :: pos_integer()
  def size, do: @size

  # OP-35 (3)
  @doc "The tenant label of a counter: the identifier of a tenant among the busiest of the last window, otherwise `other`; `nil` is `other`."
  @spec label(String.t() | nil) :: String.t()
  def label(nil), do: "other"

  def label(tenant) when is_binary(tenant) do
    if :ets.whereis(@top) != :undefined and :ets.member(@top, tenant), do: tenant, else: "other"
  end

  # TN-62
  @doc "Counts one processed job of a tenant in a queue."
  @spec count_job(String.t(), String.t()) :: :ok
  def count_job(queue, tenant),
    do: GenServer.cast(__MODULE__, {:bump, [{:tenant, tenant}, {:queue, queue, tenant}]})

  # TN-62
  @doc "Counts one API request of an API client."
  @spec count_client(String.t()) :: :ok
  def count_client(client), do: GenServer.cast(__MODULE__, {:bump, [{:client, client}]})

  # OP-35 (3)
  # TN-62
  @doc "Closes the window now: refreshes the busiest tenants, emits the shares and starts a new window."
  @spec close() :: :ok
  def close, do: GenServer.call(__MODULE__, :close)

  @impl GenServer
  def init(nil) do
    Process.flag(:message_queue_data, :off_heap)
    :ets.new(@counts, [:named_table, :protected, :set])
    :ets.new(@top, [:named_table, :protected, :set, read_concurrency: true])
    :ok = Handlers.attach()
    {:ok, MapSet.new(), {:continue, :schedule}}
  end

  @impl GenServer
  def handle_continue(:schedule, state) do
    Process.send_after(self(), :close, @window_ms)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:close, keys), do: {:noreply, close_window(keys), {:continue, :schedule}}

  @impl GenServer
  def handle_call(:close, _from, keys), do: {:reply, :ok, close_window(keys)}

  @impl GenServer
  def handle_cast({:bump, keys}, state) do
    for key <- keys, do: :ets.update_counter(@counts, key, 1, {key, 0})
    {:noreply, state}
  end

  defp close_window(previous) do
    rows = :ets.tab2list(@counts)
    :ets.delete_all_objects(@counts)

    top =
      rows
      |> Enum.flat_map(fn
        {{:tenant, tenant}, count} -> [{tenant, count}]
        _row -> []
      end)
      |> Enum.sort_by(fn {_tenant, count} -> count end, :desc)
      |> Enum.take(@size)
      |> Enum.map(fn {tenant, _count} -> tenant end)

    :ets.insert(@top, Enum.map(top, &{&1}))
    for {tenant} <- :ets.tab2list(@top), tenant not in top, do: :ets.delete(@top, tenant)

    shares =
      rows
      |> Enum.flat_map(&share_key/1)
      |> Enum.group_by(fn {key, _count} -> key end, fn {_key, count} -> count end)

    Enum.each(shares, &emit_share/1)
    for key <- previous, not Map.has_key?(shares, key), do: emit_share({key, [0]})
    shares |> Map.keys() |> MapSet.new()
  end

  defp share_key({{:queue, queue, _tenant}, count}), do: [{{"queue_tenant", queue}, count}]
  defp share_key({{:client, _client}, count}), do: [{{"api_client", "api"}, count}]
  defp share_key(_row), do: []

  defp emit_share({{signal, queue}, counts}) do
    total = Enum.sum(counts)
    share = if total >= @min_volume, do: Enum.max(counts) / total, else: 0.0
    meta = %{signal: signal, queue: queue}
    :telemetry.execute([:relay, :neighbours, :share], %{share: share}, meta)
  end
end
