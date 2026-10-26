defmodule Relay.Platform.LoadShed do
  @moduledoc """
  Load shedding by queue delay (CoDel). The trigger is the delay a job has waited when it could start, never the queue depth: a lane whose delay stays above its target for a whole interval engages, and one whose delay stays at or below the target for a whole interval releases.

  | Lane | Target | Interval | While engaged | Rule |
  |---|---|---|---|---|
  | `l0` | 500 ms | 5 s | nothing but an alarm; an expired job closes itself when it starts (TTL + FIFO) | `load_shed.l0_alarm` |
  | `l1` | 5 s | 30 s | a starting `l1` delivery job is postponed, as a last resort | `load_shed.l1` |
  | `l2` | 60 s | 5 min | the `l2` DRR rounds stop; a starting `l2` delivery job is postponed | `load_shed.l2` |
  | `l3` | 30 min | 30 min | the `l3` DRR rounds stop; running campaigns pause; the queue is kept | `load_shed.l3` |

  The order is `l3` → `l2` → `l1`, and `l0` is never shed: a lane engages only once every lower lane with work in its queues is engaged, and a lane releases only once every higher lane but `l0` has released. A lane without a job in its queues counts as idle.

  The values are code, not configuration, and stay engineering assumptions until they are measured. Every transition is recorded with its rule in `relay.load_shed_events`, and every postponed delivery job writes `delivery.held` with the rule and the time it is held until; its snooze is the lane's interval plus the deterministic snooze jitter. Each node keeps the current state in `:persistent_term`, kept fresh by `Relay.Platform.LoadShed.Watcher`; a node that never read it treats every lane as released.
  """

  alias Relay.Platform.Lane

  @params %{
    l0: %{target_ms: 500, interval_ms: 5_000, rule_id: "load_shed.l0_alarm", action: :alarm},
    l1: %{target_ms: 5_000, interval_ms: 30_000, rule_id: "load_shed.l1", action: :defer},
    l2: %{target_ms: 60_000, interval_ms: 300_000, rule_id: "load_shed.l2", action: :defer},
    l3: %{target_ms: 1_800_000, interval_ms: 1_800_000, rule_id: "load_shed.l3", action: :pause}
  }
  @state_key {__MODULE__, :engaged}

  @type params :: %{
          target_ms: pos_integer(),
          interval_ms: pos_integer(),
          rule_id: String.t(),
          action: :alarm | :defer | :pause
        }
  @type lane_state :: %{
          engaged: boolean(),
          above_since: integer() | nil,
          below_since: integer() | nil
        }
  @type states :: %{Lane.t() => lane_state()}
  @type sample :: non_neg_integer() | nil
  @type transition :: %{
          lane: Lane.t(),
          phase: :engaged | :released,
          rule_id: String.t(),
          sample_ms: non_neg_integer(),
          target_ms: pos_integer(),
          interval_ms: pos_integer()
        }
  @type hold_result :: :run | {:snooze, pos_integer()} | {:done, atom()} | {:error, term()}

  # T-34 (1)
  # T-89
  @doc "The CoDel parameters, the action and the rule of a lane."
  @spec params(Lane.t()) :: params()
  def params(lane), do: Map.fetch!(@params, lane)

  @doc "The initial state of every lane: released, with no timer running."
  @spec initial() :: states()
  def initial,
    do: Map.new(Lane.all(), &{&1, %{engaged: false, above_since: nil, below_since: nil}})

  # T-34 (1)
  @doc """
  The CoDel law for one lane: the new state after a delay sample taken at `now_ms` (`nil` when the lane's queues hold no available job) and the transition it asks for, if any.
  """
  @spec codel(Lane.t(), lane_state(), sample(), integer()) ::
          {lane_state(), :engaged | :released | nil}
  def codel(lane, state, sample, now_ms) do
    %{target_ms: target, interval_ms: interval} = params(lane)

    if is_integer(sample) and sample > target do
      since = state.above_since || now_ms
      state = %{state | above_since: since, below_since: nil}
      {state, if(not state.engaged and now_ms - since >= interval, do: :engaged)}
    else
      since = state.below_since || now_ms
      state = %{state | below_since: since, above_since: nil}
      {state, if(state.engaged and now_ms - since >= interval, do: :released)}
    end
  end

  # T-34
  # INV-24
  @doc """
  One controller step over all lanes: applies `codel/4` to each sample and the shedding order, and returns the new states with the transitions to record.
  """
  @spec control(states(), %{Lane.t() => sample()}, integer()) :: {states(), [transition()]}
  def control(states, samples, now_ms) do
    stepped =
      Map.new(Lane.all(), fn lane ->
        state = Map.get(states, lane) || Map.fetch!(initial(), lane)
        {lane, codel(lane, state, Map.get(samples, lane), now_ms)}
      end)

    {states, transitions} =
      Enum.reduce([:l0, :l3, :l2, :l1], {Map.new(stepped, fn {l, {s, _}} -> {l, s} end), []}, fn
        lane, {acc, out} ->
          {_state, wanted} = Map.fetch!(stepped, lane)
          apply_engage(lane, wanted, acc, out, samples)
      end)

    {states, transitions} =
      Enum.reduce([:l1, :l2, :l3], {states, transitions}, fn lane, {acc, out} ->
        {_state, wanted} = Map.fetch!(stepped, lane)
        apply_release(lane, wanted, acc, out, samples)
      end)

    {states, Enum.reverse(transitions)}
  end

  defp apply_engage(lane, :engaged, states, out, samples) do
    if engage_allowed?(lane, states, samples),
      do: {put_in(states[lane].engaged, true), [transition(lane, :engaged, samples) | out]},
      else: {states, out}
  end

  defp apply_engage(_lane, _wanted, states, out, _samples), do: {states, out}

  defp apply_release(lane, :released, states, out, samples) do
    if release_allowed?(lane, states),
      do: {put_in(states[lane].engaged, false), [transition(lane, :released, samples) | out]},
      else: {states, out}
  end

  defp apply_release(_lane, _wanted, states, out, _samples), do: {states, out}

  defp engage_allowed?(:l0, _states, _samples), do: true

  defp engage_allowed?(lane, states, samples),
    do: Enum.all?(lower(lane), &(states[&1].engaged or is_nil(Map.get(samples, &1))))

  defp release_allowed?(lane, states),
    do: not Enum.any?(higher(lane), &states[&1].engaged)

  defp lower(:l1), do: [:l2, :l3]
  defp lower(:l2), do: [:l3]
  defp lower(:l3), do: []

  defp higher(:l1), do: []
  defp higher(:l2), do: [:l1]
  defp higher(:l3), do: [:l1, :l2]

  defp transition(lane, phase, samples) do
    %{target_ms: target, interval_ms: interval, rule_id: rule_id} = params(lane)

    %{
      lane: lane,
      phase: phase,
      rule_id: rule_id,
      sample_ms: Map.get(samples, lane) || 0,
      target_ms: target,
      interval_ms: interval
    }
  end

  @doc "Encodes lane states for the singleton task state."
  @spec dump(states()) :: map()
  def dump(states) do
    Map.new(states, fn {lane, state} ->
      {Atom.to_string(lane),
       %{
         "engaged" => state.engaged,
         "above_since" => state.above_since,
         "below_since" => state.below_since
       }}
    end)
  end

  @doc "Decodes lane states saved by `dump/1`; missing or malformed lanes start released."
  @spec load(map() | nil) :: states()
  def load(saved) when is_map(saved) do
    Map.new(initial(), fn {lane, default} ->
      case Map.get(saved, Atom.to_string(lane)) do
        %{"engaged" => engaged} = state when is_boolean(engaged) ->
          {lane,
           %{
             engaged: engaged,
             above_since: integer_or_nil(state["above_since"]),
             below_since: integer_or_nil(state["below_since"])
           }}

        _other ->
          {lane, default}
      end
    end)
  end

  def load(nil), do: initial()

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  # T-34 (2)
  @doc "True while shedding is engaged for the lane on this node's last known state."
  @spec engaged?(Lane.t()) :: boolean()
  def engaged?(lane), do: Map.get(:persistent_term.get(@state_key, %{}), lane, false)

  @doc "This node's last known engaged lanes."
  @spec engaged() :: %{Lane.t() => boolean()}
  def engaged,
    do: Map.merge(Map.new(Lane.all(), &{&1, false}), :persistent_term.get(@state_key, %{}))

  @doc "Replaces this node's known state; written only when it changes."
  @spec put_engaged(%{Lane.t() => boolean()}) :: :ok
  def put_engaged(engaged) when is_map(engaged) do
    if :persistent_term.get(@state_key, nil) != engaged,
      do: :persistent_term.put(@state_key, engaged)

    :ok
  end

  # T-34 (2)
  # T-34 (3)
  # T-34 (4)
  # INV-24
  @doc """
  Decides whether a delivery job that is starting runs or is postponed. `l0` and `l3` delivery jobs always run; an `l1` or `l2` job is postponed while its lane is engaged: `hold` records `delivery.held` with the rule and the hold time, and the job snoozes for the lane's interval plus the jitter of its `k`-th postponement. `{:done, result}` reports a delivery that is already terminal or gone.
  """
  @spec hold(Relay.Scope.t(), Lane.t(), Relay.Id.t(), non_neg_integer(), module()) ::
          hold_result()
  def hold(scope, lane, delivery_id, k, hold_module \\ hold_module())

  def hold(_scope, lane, _delivery_id, _k, _hold_module) when lane in [:l0, :l3], do: :run

  def hold(%Relay.Scope{} = scope, lane, delivery_id, k, hold_module) when lane in [:l1, :l2] do
    if engaged?(lane), do: postpone(scope, lane, delivery_id, k, hold_module), else: :run
  end

  defp postpone(scope, lane, delivery_id, k, hold_module) do
    %{interval_ms: interval, rule_id: rule_id} = params(lane)

    wait_ms =
      Relay.Jitter.snooze(
        scope.tenant_id,
        scope.environment,
        Relay.Id.to_string(delivery_id),
        k,
        interval
      )

    until = DateTime.add(Relay.Clock.utc_now(), wait_ms, :millisecond)

    case hold_module.hold(scope, delivery_id, rule_id, until) do
      {:ok, :held} -> {:snooze, div(wait_ms + 999, 1_000)}
      {:ok, result} -> {:done, result}
      {:error, error} -> {:error, error}
    end
  end

  defp hold_module,
    do:
      :relay
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:hold, Relay.Platform.LoadShed.HoldStore)
end
