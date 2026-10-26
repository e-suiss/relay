defmodule Relay.Platform.LoadShedStoreTest do
  use Relay.SqlCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Platform.LoadShed

  @record "SELECT relay_ops.load_shed_record($1, $2, $3, $4, $5, $6, $7, $8)"

  defp lease!(name \\ "load_shed_controller") do
    [result, token] =
      row(
        "SELECT * FROM relay_ops.singleton_acquire($1, $2, interval '30 seconds')",
        [name, "test-node-" <> Base.encode16(:crypto.strong_rand_bytes(4))]
      )

    if result == "held_by_other", do: flunk("#{name} is leased by another node")
    token
  end

  defp record(lane, phase, rule_id, token),
    do: one(@record, [id(), lane, phase, rule_id, 61_000, 60_000, 300_000, token])

  defp state,
    do:
      Map.new(rows("SELECT lane, phase, rule_id FROM relay_ops.load_shed_state()"), fn [l, p, r] ->
        {l, {p, r}}
      end)

  describe "T-34 (4) INV-24 load shedding transitions" do
    test "T-34 (4): a transition is recorded once with its rule; a repeat of the same phase is unchanged" do
      token = lease!()
      assert record("l2", "engaged", "load_shed.l2", token) == "recorded"
      assert record("l2", "engaged", "load_shed.l2", token) == "unchanged"
      assert state()["l2"] == {"engaged", "load_shed.l2"}
      assert record("l2", "released", "load_shed.l2", token) == "recorded"
      assert state()["l2"] == {"released", "load_shed.l2"}
    end

    test "T-34: a lane that never engaged cannot be released" do
      token = lease!()
      assert record("l1", "released", "load_shed.l1", token) == "unchanged"
    end

    test "T-12: a stale fencing token records nothing" do
      token = lease!()
      assert record("l3", "engaged", "load_shed.l3", token + 1) == "not_leader"
      refute Map.has_key?(state(), "l3")
    end

    test "INV-24: l0 transitions carry only the alarm rule, in the function and in the table" do
      token = lease!()
      assert record("l0", "engaged", "load_shed.l0_alarm", token) == "recorded"

      assert error_message(@record, [id(), "l0", "engaged", "load_shed.l1", 1, 1, 1, token]) ==
               "invalid_argument"

      assert one(
               "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'load_shed_events_l0_check'"
             ) =~ "load_shed.l0_alarm"
    end

    test "INV-6: the transition log is append-only" do
      token = lease!()
      assert record("l1", "engaged", "load_shed.l1", token) == "recorded"

      assert sql_error("UPDATE relay.load_shed_events SET phase = 'released'").postgres.code ==
               :insufficient_privilege
    end

    test "T-34 (1): the sample is the delay of the oldest available job of a queue, not the queue depth" do
      for {queue, age_s, priority} <- [{"l1", 7, 3}, {"l1", 2, 0}, {"l1", 1, 0}, {"l2", 0, 1}] do
        rows(
          "INSERT INTO relay_queue.oban_jobs (state, queue, worker, args, priority, scheduled_at) VALUES ('available', $1, 'RelayTest.LoadShedWorker', '{}', $2, timezone('UTC', now()) - make_interval(secs => $3))",
          [queue, priority, age_s]
        )
      end

      assert {:ok, now_ms, delays} =
               Relay.Platform.LoadShed.Store.sample(["l1", "l2", "l3"], Relay.Repo)

      assert is_integer(now_ms)
      assert delays["l1"] in 7_000..7_999
      assert delays["l2"] in 0..999
      assert delays["l3"] == nil
    end

    test "T-34 (4): a controller step records the transition its saved timers ask for" do
      owner = Sandbox.start_owner!(Relay.QueueRepo, shared: false)
      on_exit(fn -> Sandbox.stop_owner(owner) end)

      on_exit(fn ->
        LoadShed.put_engaged(%{l0: false, l1: false, l2: false, l3: false})
      end)

      token = lease!()
      assert record("l3", "engaged", "load_shed.l3", token) == "recorded"
      saved = %{"l3" => %{"engaged" => true, "above_since" => nil, "below_since" => 0}}

      assert {:ok, state} = Relay.Platform.load_shed_step(token, saved)
      assert state["l3"]["engaged"] == false
      assert state()["l3"] == {"released", "load_shed.l3"}
      refute Relay.Platform.load_shed_engaged?(:l3)

      engaged = %{"l3" => %{"engaged" => true, "above_since" => nil, "below_since" => 0}}
      assert Relay.Platform.load_shed_step(token + 1, engaged) == :not_leader
    end

    test "T-34 (4): a malformed rule or a negative sample is a contract violation" do
      token = lease!()

      assert error_message(@record, [id(), "l2", "engaged", "Bad Rule", 1, 1, 1, token]) ==
               "invalid_argument"

      assert error_message(@record, [id(), "l2", "engaged", "load_shed.l2", -1, 1, 1, token]) ==
               "invalid_argument"

      assert error_message(@record, [id(), "l5", "engaged", "load_shed.l2", 1, 1, 1, token]) ==
               "invalid_argument"
    end
  end
end
