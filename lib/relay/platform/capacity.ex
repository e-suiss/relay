defmodule Relay.Platform.Capacity do
  @moduledoc """
  The capacity of the bulk lanes for admission control (T-35 (2)): `L_max = μ · W_max`, and work above it is refused at the entrance instead of queued, because queuing it would promise a wait the lane cannot keep.

  * `W_max` is the lane's queue delay target of load shedding (`Relay.Platform.LoadShed.params/1`): 60 s for `l2`, 30 min for `l3`.
  * `queued` is the lane's backlog: the available jobs of its queues and the DRR wait rows that are due.
  * `μ` is the lane's service rate in jobs per second: the configured rate (`config :relay, Relay.Platform.Capacity, service_rate: %{l2: 50, l3: 10}`) when there is one, else the jobs of the lane's queues completed in the last 60 s divided by 60. A lane with no configured rate and no completed job has no known rate and is not checked; an unmeasured lane is never a reason to refuse.

  Each node samples `relay_ops.lane_capacity` every 5 s (`Relay.Platform.Capacity.Sampler`, unless `sampler: false`) and keeps the result in an ETS table it owns; a node that never sampled knows no capacity and admits. `l0` and `l1` are never checked against `L_max`.

  Each sample also moves the lanes' input rate ceilings (`Relay.Platform.Aimd`, T-97), kept in the same table; the theoretical arrival time each lane's ceiling is enforced with lives in a second, public table of the node, written with compare-and-swap by the requests themselves (`admit_input/2`) on the monotonic clock of `Relay.Clock`. Both tables hold one entry per lane, never one per tenant. A lane without a ceiling, and a node that never sampled, does not limit input.
  """

  alias Relay.Platform.Admission
  alias Relay.Platform.Aimd
  alias Relay.Platform.Capacity.Store
  alias Relay.Platform.Lane
  alias Relay.Platform.LoadShed

  @lanes [:l2, :l3]
  @window_s 60
  @table __MODULE__
  @input Module.concat(__MODULE__, Input)

  @type t :: %{optional(Lane.t()) => Admission.capacity() | nil}

  @doc "The sampling window of the measured service rate, in seconds."
  @spec window_s() :: pos_integer()
  def window_s, do: @window_s

  @doc "The configured service rates per lane, in jobs per second."
  @spec service_rates() :: %{optional(Lane.t()) => number()}
  def service_rates,
    do: :relay |> Application.get_env(__MODULE__, []) |> Keyword.get(:service_rate, %{})

  # T-35 (2)
  @doc "Builds the lane capacities from `relay_ops.lane_capacity` rows, the configured rates and the window."
  @spec build([map()], %{optional(Lane.t()) => number()}, pos_integer()) :: t()
  def build(rows, rates, window_s) do
    by_lane = Map.new(rows, &{&1["lane"], &1})

    Map.new(@lanes, fn lane ->
      row = Map.get(by_lane, Atom.to_string(lane), %{})
      queued = row["queued"] || 0
      {lane, capacity(lane, rate(Map.get(rates, lane), row["completed"], window_s), queued)}
    end)
  end

  defp rate(configured, _completed, _window_s) when is_number(configured) and configured > 0,
    do: configured

  defp rate(_configured, completed, window_s) when is_integer(completed) and completed > 0,
    do: completed / window_s

  defp rate(_configured, _completed, _window_s), do: nil

  defp capacity(_lane, nil, _queued), do: nil
  defp capacity(lane, mu, queued), do: {mu, LoadShed.params(lane).target_ms, queued}

  @doc "This node's last sampled lane capacities, `nil` when it never sampled."
  @spec current() :: t() | nil
  def current do
    case :ets.whereis(@table) do
      :undefined -> nil
      _table -> lookup()
    end
  end

  defp lookup do
    case :ets.lookup(@table, :capacity) do
      [{:capacity, capacity}] -> capacity
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Puts the lane capacities of this node; `nil`, a node that never sampled, also clears the input ceilings."
  @spec put(t() | nil) :: :ok
  def put(capacity) do
    :ok = table()
    true = :ets.insert(@table, {:capacity, capacity})
    if capacity == nil, do: put_ceilings(%{})
    :ok
  end

  # T-97
  @doc "This node's input rate ceilings per lane, in requests per second; a lane without one is absent or `nil`."
  @spec ceilings() :: %{optional(Lane.t()) => Aimd.ceiling() | nil}
  def ceilings do
    case :ets.whereis(@table) do
      :undefined -> %{}
      _table -> lookup_ceilings()
    end
  end

  defp lookup_ceilings do
    case :ets.lookup(@table, :ceilings) do
      [{:ceilings, ceilings}] -> ceilings
      [] -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  # T-97
  @doc "Puts the input rate ceilings of this node and forgets the arrival times of the lanes it no longer limits."
  @spec put_ceilings(%{optional(Lane.t()) => Aimd.ceiling() | nil}) :: :ok
  def put_ceilings(ceilings) do
    :ok = table()
    true = :ets.insert(@table, {:ceilings, ceilings})

    for lane <- @lanes, Map.get(ceilings, lane) == nil, do: :ets.delete(@input, lane)

    :ok
  end

  # T-97
  # T-35 (5)
  @doc "Spends one request of `lane`'s input under its ceiling: `:ok`, or `{:deny, retry_after_ms}` when the input is above it. Options: `:clock`, a `Relay.Clock` implementation."
  @spec admit_input(Lane.t(), keyword()) :: :ok | {:deny, pos_integer()}
  def admit_input(lane, opts \\ []) do
    case Map.get(ceilings(), lane) do
      ceiling when is_number(ceiling) and ceiling > 0 ->
        now_us = Keyword.get(opts, :clock, Relay.Clock).monotonic_ms() * 1_000
        spend(lane, ceiling, now_us)

      _none ->
        :ok
    end
  end

  defp spend(lane, ceiling, now_us) do
    previous =
      case :ets.lookup(@input, lane) do
        [{^lane, tat}] -> tat
        [] -> nil
      end

    with {:allow, tat} <- Aimd.admit(ceiling, previous, now_us) do
      if store(lane, previous, tat), do: :ok, else: spend(lane, ceiling, now_us)
    end
  rescue
    ArgumentError -> :ok
  end

  defp store(lane, nil, tat), do: :ets.insert_new(@input, {lane, tat})

  defp store(lane, previous, tat),
    do: :ets.select_replace(@input, [{{lane, previous}, [], [{{{:const, lane}, tat}}]}]) == 1

  @doc "Creates this node's capacity tables when they do not exist; the sampler owns them."
  @spec table() :: :ok
  def table do
    if :ets.whereis(@table) == :undefined,
      do: :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

    if :ets.whereis(@input) == :undefined,
      do: :ets.new(@input, [:named_table, :public, :set, write_concurrency: true])

    :ok
  rescue
    ArgumentError -> :ok
  end

  # T-35 (2)
  @doc "Samples the lane backlogs and completions now and puts the capacities and the moved input ceilings of this node."
  @spec sample() :: {:ok, t()} | {:error, Relay.Error.t()}
  def sample do
    with {:ok, rows} <- Store.lane_capacity(@window_s) do
      capacity = build(rows, service_rates(), @window_s)
      :ok = put(capacity)
      :ok = put_ceilings(step(ceilings(), capacity))
      {:ok, capacity}
    end
  end

  # T-97
  @doc "Moves every bulk lane's input ceiling by one sample of the lane capacities."
  @spec step(%{optional(Lane.t()) => Aimd.ceiling() | nil}, t()) ::
          %{optional(Lane.t()) => Aimd.ceiling() | nil}
  def step(ceilings, capacity) do
    Map.new(@lanes, &{&1, Aimd.step(Map.get(ceilings, &1), Map.get(capacity, &1))})
  end
end
