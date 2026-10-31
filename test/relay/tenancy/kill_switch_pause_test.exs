defmodule Relay.Tenancy.KillSwitchPauseTest do
  use Relay.SqlCase, async: false

  alias Relay.Policy.Lattice.Fake
  alias Relay.Tenancy.KillSwitch
  alias Relay.Tenancy.KillSwitch.Snapshot
  alias Relay.Tenancy.KillSwitch.Store
  alias Relay.Tenancy.KillSwitch.Sweep
  alias RelayTest.TenantFixture.SendWorker

  @operator %{kind: :installation_operator, ref: "ops@example"}

  defp later, do: DateTime.add(DateTime.utc_now(), 3600, :second)

  defp engage!(scope, attrs \\ []) do
    spec =
      Map.merge(
        %{scope_kind: :tenant, scope: scope, reason: "incident 7", expires_at: later()},
        Map.new(attrs)
      )

    {:ok, %{result: :engaged, id: external}} = KillSwitch.engage(spec, @operator)
    {:ok, id} = Relay.ExternalId.decode(external, ["ksw"])
    {external, id}
  end

  defp snapshot do
    {:ok, generation, records} = Store.snapshot()
    Snapshot.new(generation, records)
  end

  defp delivery_state(delivery_id) do
    row(
      "SELECT paused_at IS NOT NULL, pause_rule_id, pause_kill_switch_id, failure_kind, failure_rule_id FROM relay.deliveries WHERE id = $1",
      [delivery_id]
    )
  end

  defp events(delivery_id) do
    for [type] <-
          rows(
            "SELECT event_type FROM relay.delivery_events WHERE delivery_id = $1 ORDER BY received_at, id",
            [delivery_id]
          ),
        do: type
  end

  defp sweep_jobs do
    rows(
      "SELECT args FROM relay_queue.oban_jobs WHERE worker = 'Relay.Tenancy.KillSwitch.Sweep' ORDER BY id"
    )
  end

  setup do
    s = scenario!()
    delivery = delivery!(s.notification)
    %{s: s, scope: Relay.Scope.new!(s.tenant, :test), delivery: delivery}
  end

  describe "TN-40 stop points" do
    test "TN-40: at acceptance a matching delivery is opened and paused in the same transaction and gets no job",
         %{scope: scope, delivery: delivery} do
      {_external, ksw} = engage!(scope, channel: "sms")
      snap = snapshot()

      assert {:ok, {:paused, "killswitch.off"}} =
               Store.in_scope(scope, fn _ ->
                 KillSwitch.at_acceptance(delivery, snapshot: snap)
               end)

      assert [true, "killswitch.off", ^ksw, nil, nil] = delivery_state(delivery)
    end

    test "TN-40: the sweep job inserted with the record pauses the pending deliveries it matches",
         %{scope: scope, delivery: delivery, s: s} do
      other = delivery!(s.notification, "email")
      {_external, ksw} = engage!(scope, channel: "sms")

      assert [[%{"kill_switch_id" => id, "platform" => false} = args]] = sweep_jobs()
      assert id == Relay.Id.to_string(ksw)
      assert :ok = Sweep.perform(%Oban.Job{args: args})

      assert [true, "killswitch.off", ^ksw, nil, nil] = delivery_state(delivery)
      assert [false, nil, nil, nil, nil] = delivery_state(other)
      assert "delivery.paused" in events(delivery)
    end

    test "TN-40: a platform record's sweep visits every tenant with pending deliveries",
         %{delivery: delivery} do
      {_external, ksw} = engage!(nil, scope_kind: :platform, channel: "sms")
      [[args]] = sweep_jobs()
      assert args["platform"] == true
      assert :ok = Sweep.perform(%Oban.Job{args: args})
      assert [true, "killswitch.off", ^ksw, nil, nil] = delivery_state(delivery)
    end

    test "T-15: the first step pauses a matching delivery without error and a paused job ends without work",
         %{scope: scope, delivery: delivery} do
      assert {:send, %{"result" => :sendable}} =
               KillSwitch.first_step(scope, delivery, snapshot: Snapshot.new(0, []))

      {_external, ksw} = engage!(scope, message_class: :transactional)
      snap = snapshot()
      assert {:done, :paused} = KillSwitch.first_step(scope, delivery, snapshot: snap)
      assert [true, "killswitch.off", ^ksw, nil, nil] = delivery_state(delivery)
      assert {:done, :paused} = KillSwitch.first_step(scope, delivery, snapshot: snap)

      assert {:done, :paused} =
               KillSwitch.first_step(scope, delivery, snapshot: Snapshot.new(0, []))
    end

    test "TN-38: without kill switch state the first step snoozes and sends nothing",
         %{scope: scope, delivery: delivery} do
      assert {:snooze, 5} = KillSwitch.first_step(scope, delivery, snapshot: :unknown)
      assert [false, nil, nil, nil, nil] = delivery_state(delivery)
    end

    test "T-15: a cancelled delivery's job ends at the first step", %{
      scope: scope,
      delivery: delivery
    } do
      "cancelled" =
        one("SELECT relay_fn.delivery_cancel($1, 'test.cancel', $2, $3, $4, $5, $6)", [
          delivery,
          digest() | actor()
        ])

      assert {:done, :cancelled} =
               KillSwitch.first_step(scope, delivery, snapshot: Snapshot.new(0, []))
    end

    test "C-65, INV-3: a pause is not a cancel and keeps the delivery", %{
      scope: scope,
      delivery: delivery
    } do
      engage!(scope)
      {:done, :paused} = KillSwitch.first_step(scope, delivery, snapshot: snapshot())
      assert [true, "killswitch.off", _, nil, nil] = delivery_state(delivery)
      refute "delivery.cancelled" in events(delivery)
    end
  end

  describe "TN-40 paused deliveries stay paused" do
    test "TN-40: releasing the record does not send a paused delivery", %{
      scope: scope,
      delivery: delivery
    } do
      {external, ksw} = engage!(scope)
      {:done, :paused} = KillSwitch.first_step(scope, delivery, snapshot: snapshot())

      assert {:ok, %{result: :released}} =
               KillSwitch.release(
                 external,
                 %{reason: "over", relax_approval: "CAB-1"},
                 @operator
               )

      refute Enum.any?(Map.values(snapshot().index), &Enum.any?(&1, fn r -> r.id == ksw end))
      assert {:done, :paused} = KillSwitch.first_step(scope, delivery, snapshot: snapshot())
    end

    test "TN-40: a paused delivery whose message expired closes as expired", %{s: s} do
      "active" = ctx(s.tenant)
      expiring = id()

      ["created", ^expiring] =
        row(
          "SELECT result, notification_id FROM relay_fn.notification_accept($1, $2, NULL, $3, 'transactional', NULL, 'system', NULL, NULL, now() - interval '1 second', false, NULL)",
          [expiring, s.recipient, "dedup-expiring"]
        )

      delivery = delivery!(expiring)
      ksw = id()
      "paused" = one("SELECT relay_fn.delivery_pause($1, 'killswitch.off', $2)", [delivery, ksw])

      assert KillSwitch.expire_paused() >= 1

      assert [true, "killswitch.off", ^ksw, "expired", "killswitch.paused_expired"] =
               delivery_state(delivery)
    end

    test "TN-70: resume with the stage 2 lattice is refused and changes nothing", %{
      scope: scope,
      delivery: delivery
    } do
      {external, _ksw} = engage!(scope)
      {:done, :paused} = KillSwitch.first_step(scope, delivery, snapshot: snapshot())

      assert {:error, :policy_lattice_unavailable} =
               KillSwitch.resume(external, %{reason: "ok", relax_approval: "CAB-2"}, @operator)

      assert [true, "killswitch.off", _, nil, nil] = delivery_state(delivery)
    end

    test "TN-40: resume through a lattice that sends lifts the pause and inserts the job in the same transaction",
         %{scope: scope, delivery: delivery} do
      {external, _ksw} = engage!(scope)
      {:done, :paused} = KillSwitch.first_step(scope, delivery, snapshot: snapshot())
      Fake.decide(fn _ -> {:send, "lattice:1"} end)

      job = fn _scope, id ->
        SendWorker.new(%{"delivery_id" => Relay.Id.to_string(id)})
      end

      assert {:ok, %{resumed: 1, cancelled: 0}} =
               KillSwitch.resume(
                 external,
                 %{
                   reason: "ok",
                   relax_approval: "CAB-3",
                   lattice: Fake,
                   job: job
                 },
                 @operator
               )

      assert [false, nil, nil, nil, nil] = delivery_state(delivery)
      assert "delivery.resumed" in events(delivery)

      assert [[_]] =
               rows(
                 "SELECT id FROM relay_queue.oban_jobs WHERE worker = 'RelayTest.TenantFixture.SendWorker' AND args ->> 'delivery_id' = $1",
                 [Relay.Id.to_string(delivery)]
               )
    end

    test "TN-40: resume through a lattice that skips cancels with the lattice's rule", %{
      scope: scope,
      delivery: delivery
    } do
      {external, _ksw} = engage!(scope)
      {:done, :paused} = KillSwitch.first_step(scope, delivery, snapshot: snapshot())
      Fake.decide(fn _ -> {:skip, "quiet hours", "policy.quiet_hours"} end)

      assert {:ok, %{resumed: 0, cancelled: 1}} =
               KillSwitch.resume(
                 external,
                 %{reason: "ok", relax_approval: "CAB-4", lattice: Fake},
                 @operator
               )

      assert [true, _, _, "cancelled", "policy.quiet_hours"] = delivery_state(delivery)
    end
  end

  describe "TN-47 bulk cancel" do
    test "TN-47: a bulk cancel cancels every paused delivery with its rule under one audit record",
         %{scope: scope, delivery: delivery, s: s} do
      second = delivery!(s.notification, "email")
      {external, ksw} = engage!(scope)
      snap = snapshot()
      {:done, :paused} = KillSwitch.first_step(scope, delivery, snapshot: snap)
      {:done, :paused} = KillSwitch.first_step(scope, second, snapshot: snap)

      assert {:ok, %{cancelled: 2, rule_id: rule_id}} =
               KillSwitch.bulk_cancel(external, %{reason: "wrong campaign"}, @operator)

      assert rule_id == "killswitch.bulk_cancel:" <> external
      assert [true, _, ^ksw, "cancelled", ^rule_id] = delivery_state(delivery)
      assert [true, _, ^ksw, "cancelled", ^rule_id] = delivery_state(second)
      assert "delivery.cancelled" in events(delivery)

      now = DateTime.utc_now()
      installation = one("SELECT relay_private.installation_tenant_id()")
      "active" = ctx(installation, "live")

      actions =
        for [action, target] <-
              rows(
                "SELECT action, target_id FROM relay_fn.audit_query($1, $2, 'killswitch.bulk_cancelled', NULL, 10, $3, $4, $5, $6, $7)",
                [DateTime.add(now, -3600), DateTime.add(now, 3600), digest() | actor()]
              ),
            target == Relay.Id.to_string(ksw),
            do: action

      assert actions == ["killswitch.bulk_cancelled"]
    end
  end
end
