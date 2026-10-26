# T-89
# T-34
{:ok, _} = Application.ensure_all_started(:tzdata)

alias Relay.Platform.Admission
alias Relay.Platform.Lane
alias Relay.Platform.LoadShed

defmodule Bench.LoadShedLatency.Hold do
  @behaviour Relay.Platform.LoadShed.Hold

  @impl true
  def hold(_scope, _delivery_id, _rule_id, _until), do: {:ok, :held}
end

defmodule Bench.LoadShedLatency do
  def ramp(lane, step_ms, minutes) do
    %{target_ms: target, interval_ms: interval} = LoadShed.params(lane)
    steps = div(minutes * 60_000, step_ms)

    {_states, first_above, engaged_at} =
      Enum.reduce(0..steps, {LoadShed.initial(), nil, nil}, fn i, {states, above, found} ->
        now = i * step_ms
        delay = div(target * 2 * i, max(steps, 1))
        samples = Map.new(Lane.all(), &{&1, nil}) |> Map.put(lane, delay)
        {states, transitions} = LoadShed.control(states, samples, now)
        above = above || if(delay > target, do: now)

        {states, above, found || engaged_at(transitions, lane, now)}
      end)

    {target, interval, first_above, engaged_at}
  end

  defp engaged_at(transitions, lane, now) do
    if Enum.any?(transitions, &(&1.lane == lane and &1.phase == :engaged)), do: now
  end
end

IO.puts("lane | target_ms | interval_ms | delay first above target at | engaged at | engage lag")

for lane <- Lane.all() do
  {target, interval, above, engaged} = Bench.LoadShedLatency.ramp(lane, 1_000, 120)
  lag = if engaged, do: engaged - above, else: "gap"
  IO.puts("#{lane} | #{target} | #{interval} | #{above} | #{engaged || "gap"} | #{lag}")
end

scope = Relay.Scope.new!(Relay.Id.generate(), :live)
overloaded = %{l0: 2_000, l1: 10_000, l2: 120_000, l3: 3_600_000}
states = LoadShed.initial()
LoadShed.put_engaged(%{l0: true, l1: true, l2: true, l3: true})

admission_input = %{
  message_class: :marketing,
  channels: [:email],
  shed: %{l1: false, l2: false, l3: false},
  breaker_open: MapSet.new(),
  lane_capacity: %{l3: {50, 1_800_000, 10_000}}
}

Benchee.run(
  %{
    "codel control step, four lanes" => fn -> LoadShed.control(states, overloaded, 1_800_000) end,
    "admission decision" => fn -> Admission.decide(admission_input) end,
    "hold decision, l1 engaged" => fn ->
      LoadShed.hold(scope, :l1, Relay.Id.generate(), 1, Bench.LoadShedLatency.Hold)
    end,
    "hold decision, l0" => fn ->
      LoadShed.hold(scope, :l0, Relay.Id.generate(), 1, Bench.LoadShedLatency.Hold)
    end
  },
  time: 5,
  memory_time: 1,
  warmup: 2,
  formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
)

LoadShed.put_engaged(%{l0: false, l1: false, l2: false, l3: false})
