defmodule Relay.Platform.LoadShedTest do
  use ExUnit.Case, async: false

  alias Relay.Platform.LoadShed
  alias Relay.Platform.LoadShed.Watcher

  defmodule FakeHold do
    @behaviour Relay.Platform.LoadShed.Hold

    @impl true
    def hold(scope, delivery_id, rule_id, until) do
      send(self(), {:held, scope, delivery_id, rule_id, until})
      {:ok, :held}
    end
  end

  defmodule GoneHold do
    @behaviour Relay.Platform.LoadShed.Hold

    @impl true
    def hold(_scope, _delivery_id, _rule_id, _until), do: {:ok, :already_terminal}
  end

  @released %{l0: false, l1: false, l2: false, l3: false}

  setup do
    LoadShed.put_engaged(@released)
    on_exit(fn -> LoadShed.put_engaged(@released) end)
    scope = Relay.Scope.new!(Relay.Id.generate(), :live)
    {:ok, scope: scope}
  end

  defp run(states, samples_by_time) do
    Enum.reduce(samples_by_time, {states, []}, fn {now, samples}, {states, seen} ->
      {states, transitions} = LoadShed.control(states, samples, now)
      {states, seen ++ Enum.map(transitions, &{now, &1.lane, &1.phase})}
    end)
  end

  defp busy(delays), do: Map.merge(%{l0: nil, l1: nil, l2: nil, l3: nil}, delays)

  describe "T-34 CoDel by queue delay" do
    test "T-34 (1): a lane engages only after its delay stays above the target for a whole interval" do
      above = busy(%{l1: 6_000})

      {_states, seen} =
        run(LoadShed.initial(), [{0, above}, {29_999, above}, {30_000, above}, {31_000, above}])

      assert seen == [{30_000, :l1, :engaged}]
    end

    test "T-34 (1): one sample at or below the target restarts the interval" do
      above = busy(%{l1: 6_000})
      below = busy(%{l1: 5_000})

      {_states, seen} =
        run(LoadShed.initial(), [
          {0, above},
          {20_000, below},
          {21_000, above},
          {50_000, above},
          {51_000, above}
        ])

      assert seen == [{51_000, :l1, :engaged}]
    end

    test "T-34 (1): an engaged lane releases after its delay stays at or below the target for a whole interval" do
      above = busy(%{l1: 6_000})
      below = busy(%{l1: 100})

      {_states, seen} =
        run(LoadShed.initial(), [
          {0, above},
          {30_000, above},
          {31_000, below},
          {60_999, below},
          {61_000, below}
        ])

      assert seen == [{30_000, :l1, :engaged}, {61_000, :l1, :released}]
    end

    test "T-34 (1): the trigger is the delay; a lane without a waiting job never engages" do
      {_states, seen} =
        run(LoadShed.initial(), for(t <- 0..40, do: {t * 60_000, busy(%{l3: 1_000, l2: 0})}))

      assert seen == []
    end

    test "T-34: the order is l3, then l2, then l1, and l1 only as the last resort" do
      overloaded = busy(%{l1: 10_000, l2: 120_000, l3: 3_600_000})
      steps = for t <- [0, 30_000, 300_000, 1_800_000], do: {t, overloaded}
      {_states, seen} = run(LoadShed.initial(), steps)

      assert seen == [
               {1_800_000, :l3, :engaged},
               {1_800_000, :l2, :engaged},
               {1_800_000, :l1, :engaged}
             ]
    end

    test "T-34: an idle lower lane does not hold a higher lane back" do
      {_states, seen} =
        run(LoadShed.initial(), [{0, busy(%{l1: 9_000})}, {30_000, busy(%{l1: 9_000})}])

      assert seen == [{30_000, :l1, :engaged}]
    end

    test "T-34: l3 and l2 release only after l1 has released" do
      overloaded = busy(%{l1: 10_000, l2: 120_000, l3: 3_600_000})
      {states, _seen} = run(LoadShed.initial(), [{0, overloaded}, {1_800_000, overloaded}])

      calm_but_l1 = busy(%{l1: 10_000, l2: 0, l3: 0})
      {states, seen} = run(states, [{1_800_001, calm_but_l1}, {3_600_001, calm_but_l1}])
      assert seen == []
      assert states.l3.engaged and states.l2.engaged

      calm = busy(%{l1: 0, l2: 0, l3: 0})
      {_states, seen} = run(states, [{3_600_002, calm}, {3_630_002, calm}])

      assert seen == [
               {3_630_002, :l1, :released},
               {3_630_002, :l2, :released},
               {3_630_002, :l3, :released}
             ]
    end

    test "T-34 (4): every transition carries its rule, the sample and the lane parameters" do
      {_states, transitions} =
        LoadShed.control(
          LoadShed.load(%{
            "l2" => %{"engaged" => false, "above_since" => 0, "below_since" => nil}
          }),
          busy(%{l2: 61_000}),
          300_000
        )

      assert transitions == [
               %{
                 lane: :l2,
                 phase: :engaged,
                 rule_id: "load_shed.l2",
                 sample_ms: 61_000,
                 target_ms: 60_000,
                 interval_ms: 300_000
               }
             ]
    end

    test "T-12: the lane timers survive a change of leader through the saved state" do
      {states, _seen} = run(LoadShed.initial(), [{0, busy(%{l1: 9_000})}])
      saved = states |> LoadShed.dump() |> Jason.encode!() |> Jason.decode!()
      assert LoadShed.load(saved) == states
      assert LoadShed.load(nil) == LoadShed.initial()
      assert LoadShed.load(%{"l1" => "garbage"}) == LoadShed.initial()
    end
  end

  describe "INV-24 l0 is never shed" do
    test "INV-24: an l0 delay over its target is only an alarm with its own rule" do
      over = busy(%{l0: 2_000})

      {_states, transitions} =
        LoadShed.control(
          LoadShed.load(%{"l0" => %{"engaged" => false, "above_since" => 0}}),
          over,
          5_000
        )

      assert [%{lane: :l0, phase: :engaged, rule_id: "load_shed.l0_alarm"}] = transitions
      assert LoadShed.params(:l0).action == :alarm
    end

    test "INV-24: an l0 delivery job runs under every shedding state", %{scope: scope} do
      for l0 <- [false, true], l1 <- [false, true], l2 <- [false, true], l3 <- [false, true] do
        LoadShed.put_engaged(%{l0: l0, l1: l1, l2: l2, l3: l3})
        assert LoadShed.hold(scope, :l0, Relay.Id.generate(), 0, FakeHold) == :run
      end

      refute_received {:held, _, _, _, _}
    end
  end

  describe "T-34 (2) T-34 (4) postponing a starting delivery job" do
    test "T-34 (4): an engaged l1 postpones the job and records delivery.held with its rule", %{
      scope: scope
    } do
      LoadShed.put_engaged(%{@released | l1: true})
      delivery = Relay.Id.generate()
      before = Relay.Clock.utc_now()

      assert {:snooze, seconds} = LoadShed.hold(scope, :l1, delivery, 2, FakeHold)
      assert_received {:held, ^scope, ^delivery, "load_shed.l1", until}

      wait =
        Relay.Jitter.snooze(
          scope.tenant_id,
          scope.environment,
          Relay.Id.to_string(delivery),
          2,
          30_000
        )

      assert wait in 30_000..36_000
      assert seconds == div(wait + 999, 1_000)
      assert DateTime.diff(until, before, :millisecond) in wait..(wait + 5_000)
      assert LoadShed.hold(scope, :l1, delivery, 2, FakeHold) == {:snooze, seconds}
    end

    test "T-34 (2): an engaged l2 postpones its delivery jobs; l3 jobs already queued still run",
         %{scope: scope} do
      LoadShed.put_engaged(%{@released | l2: true, l3: true})
      assert {:snooze, _} = LoadShed.hold(scope, :l2, Relay.Id.generate(), 0, FakeHold)
      assert_received {:held, _, _, "load_shed.l2", _}
      assert LoadShed.hold(scope, :l3, Relay.Id.generate(), 0, FakeHold) == :run
    end

    test "T-34: a released lane runs its jobs", %{scope: scope} do
      for lane <- [:l1, :l2],
          do: assert(LoadShed.hold(scope, lane, Relay.Id.generate(), 0, FakeHold) == :run)

      refute_received {:held, _, _, _, _}
    end

    test "T-34: a delivery that is no longer waiting is reported, not snoozed", %{scope: scope} do
      LoadShed.put_engaged(%{@released | l1: true})

      assert LoadShed.hold(scope, :l1, Relay.Id.generate(), 0, GoneHold) ==
               {:done, :already_terminal}
    end

    test "T-86: the watcher turns the last transition of every lane into the engaged lanes" do
      rows = [
        %{"lane" => "l1", "phase" => "released", "rule_id" => "load_shed.l1"},
        %{"lane" => "l3", "phase" => "engaged", "rule_id" => "load_shed.l3"}
      ]

      assert Watcher.engaged(rows) == %{@released | l3: true}
      assert Watcher.engaged([]) == @released
    end

    test "T-34: a node that never read the state treats every lane as released" do
      :persistent_term.erase({LoadShed, :engaged})
      refute Enum.any?(Relay.Platform.Lane.all(), &LoadShed.engaged?/1)
      assert LoadShed.engaged() == @released
    end
  end
end
