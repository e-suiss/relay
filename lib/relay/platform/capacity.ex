defmodule Relay.Platform.Capacity do
  @moduledoc """
  The capacity of the bulk lanes for admission control (T-35 (2)): `L_max = μ · W_max`, and work above it is refused at the entrance instead of queued, because queuing it would promise a wait the lane cannot keep.

  * `W_max` is the lane's queue delay target of load shedding (`Relay.Platform.LoadShed.params/1`): 60 s for `l2`, 30 min for `l3`.
  * `queued` is the lane's backlog: the available jobs of its queues and the DRR wait rows that are due.
  * `μ` is the lane's service rate in jobs per second: the configured rate (`config :relay, Relay.Platform.Capacity, service_rate: %{l2: 50, l3: 10}`) when there is one, else the jobs of the lane's queues completed in the last 60 s divided by 60. A lane with no configured rate and no completed job has no known rate and is not checked; an unmeasured lane is never a reason to refuse.

  Each node samples `relay_ops.lane_capacity` every 5 s (`Relay.Platform.Capacity.Sampler`, unless `sampler: false`) and keeps the result in a public ETS table; a node that never sampled knows no capacity and admits. `l0` and `l1` are never checked against `L_max`.
  """

  alias Relay.Platform.Admission
  alias Relay.Platform.Capacity.Store
  alias Relay.Platform.Lane
  alias Relay.Platform.LoadShed

  @lanes [:l2, :l3]
  @window_s 60
  @table __MODULE__

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

  @doc "Puts the lane capacities of this node."
  @spec put(t() | nil) :: :ok
  def put(capacity) do
    :ok = table()
    true = :ets.insert(@table, {:capacity, capacity})
    :ok
  end

  @doc "Creates this node's capacity table when it does not exist; the sampler owns it."
  @spec table() :: :ok
  def table do
    if :ets.whereis(@table) == :undefined,
      do: :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    :ok
  rescue
    ArgumentError -> :ok
  end

  # T-35 (2)
  @doc "Samples the lane backlogs and completions now and puts the capacities of this node."
  @spec sample() :: {:ok, t()} | {:error, Relay.Error.t()}
  def sample do
    with {:ok, rows} <- Store.lane_capacity(@window_s) do
      capacity = build(rows, service_rates(), @window_s)
      :ok = put(capacity)
      {:ok, capacity}
    end
  end
end
