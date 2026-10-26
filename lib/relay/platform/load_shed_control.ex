defmodule Relay.Platform.LoadShed.Control do
  @moduledoc """
  One step of the `load_shed_controller` singleton task: sample the queue delay of every lane on the database clock, apply the CoDel law and the shedding order (`Relay.Platform.LoadShed.control/3`), record each transition under the controller's fencing token, and announce it on the `relay:s:signal:load_shed` signal. The lane timers live in the task state, so a new leader continues them.

  Telemetry: `[:relay, :load_shed, :transition]` for every recorded transition with the lane, phase and rule, `[:relay, :load_shed, :delay]` with each lane's sample; an engaged `l0` is an alarm and is logged as an error.
  """

  require Logger

  alias Relay.Platform.Lane
  alias Relay.Platform.LoadShed
  alias Relay.Platform.LoadShed.Store
  alias Relay.Platform.Signal
  alias Relay.Platform.Valkey.Key

  # T-34 (1)
  # T-34 (4)
  # T-12
  @doc "Runs one controller step from the saved task state and returns the state to save."
  @spec step(pos_integer(), map() | nil) :: {:ok, map()} | :not_leader | {:error, Relay.Error.t()}
  def step(fencing_token, saved) do
    queues = Map.new(Lane.all(), &{&1, Lane.lane_queues(&1)})

    with {:ok, now_ms, delays} <- Store.sample(queues |> Map.values() |> List.flatten()),
         samples = Map.new(queues, fn {lane, names} -> {lane, lane_delay(names, delays)} end),
         :ok <- Enum.each(samples, fn {lane, delay} -> report(lane, delay) end),
         {states, transitions} = LoadShed.control(LoadShed.load(saved), samples, now_ms),
         :ok <- record(transitions, fencing_token) do
      if transitions != [], do: announce(states, now_ms)
      {:ok, LoadShed.dump(states)}
    end
  end

  @doc "The signal topic that announces a load shedding transition."
  @spec topic() :: Signal.topic()
  def topic, do: Key.system_channel(["signal", "load_shed"])

  defp lane_delay(names, delays) do
    names
    |> Enum.map(&Map.get(delays, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp report(lane, delay),
    do: :telemetry.execute([:relay, :load_shed, :delay], %{ms: delay || 0}, %{lane: lane})

  defp record(transitions, token) do
    Enum.reduce_while(transitions, :ok, fn transition, :ok ->
      case Store.record(Relay.Id.generate(), transition, token) do
        {:ok, result} ->
          observe(transition, result)
          {:cont, :ok}

        other ->
          {:halt, other}
      end
    end)
  end

  defp observe(transition, result) do
    :telemetry.execute(
      [:relay, :load_shed, :transition],
      %{count: 1},
      Map.take(transition, [:lane, :phase, :rule_id]) |> Map.put(:result, result)
    )

    if transition.lane == :l0 and transition.phase == :engaged,
      do: Logger.error("l0 queue delay above its target", rule_id: transition.rule_id),
      else:
        Logger.warning("load shedding transition",
          lane: transition.lane,
          phase: transition.phase,
          rule_id: transition.rule_id
        )
  end

  defp announce(states, now_ms) do
    :ok = LoadShed.put_engaged(Map.new(states, fn {lane, state} -> {lane, state.engaged} end))

    case Signal.publish(topic(), max(now_ms, 0)) do
      :ok -> :ok
      {:error, error} -> Logger.warning("load shedding signal not sent", code: error.code)
    end
  end
end
