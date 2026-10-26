defmodule Relay.Delivery.DeliveryGateTest do
  use Relay.DataCase, async: false

  alias Relay.Delivery
  alias Relay.Repo
  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture
  alias RelayTest.TenantFixture.SendWorker

  setup do
    TenantFixture.as_role("relay_worker")
    DeliveryFixture.sendable!()
  end

  defp events(scope, id) do
    {:ok, ledger} = Delivery.ledger(scope, id)
    Enum.map(ledger, & &1["event_type"])
  end

  defp actor, do: TenantFixture.actor()

  describe "T-15 (5) gate" do
    test "T-15 (5): a pending delivery is sendable and the gate carries what the job needs",
         ctx do
      assert {:ok,
              %{
                result: :sendable,
                channel: "email",
                message_class: "transactional",
                attempt_count: 0
              } = gate} =
               Delivery.gate(ctx.scope, ctx.delivery_id)

      assert gate.notification_id == ctx.notification_id
      assert {:ok, %{result: :not_found}} = Delivery.gate(ctx.scope, Relay.Id.generate())
    end

    test "T-15 (5), TN-40: cancelled, paused, terminal, expired and deferred deliveries are not sendable",
         ctx do
      {:ok, :paused} = Delivery.pause(ctx.scope, ctx.delivery_id, "killswitch.test", nil)
      assert {:ok, %{result: :paused}} = Delivery.gate(ctx.scope, ctx.delivery_id)

      {:ok, :cancelled} =
        Delivery.cancel_delivery(
          ctx.scope,
          ctx.delivery_id,
          "killswitch.bulk_cancel",
          TenantFixture.digest(),
          actor()
        )

      assert {:ok, %{result: :cancelled}} = Delivery.gate(ctx.scope, ctx.delivery_id)

      expired =
        DeliveryFixture.sendable!(
          notification: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert {:ok, %{result: :expired, expires_at: %DateTime{}}} =
               Delivery.gate(expired.scope, expired.delivery_id)

      assert {:ok, :expired} = Delivery.expire(expired.scope, expired.delivery_id, "gate.expired")
      assert {:ok, %{result: :terminal}} = Delivery.gate(expired.scope, expired.delivery_id)

      assert {:ok, :already_terminal} =
               Delivery.expire(expired.scope, expired.delivery_id, "gate.expired")

      deferred =
        DeliveryFixture.sendable!(
          delivery: [
            decision: :defer,
            decision_rule_id: "quiet_hours",
            decision_reason: "test",
            deferred_until: DateTime.add(DateTime.utc_now(), 3600, :second)
          ]
        )

      assert {:ok, %{result: :deferred}} = Delivery.gate(deferred.scope, deferred.delivery_id)
    end
  end

  describe "TN-40 pause" do
    test "TN-40, C-65: a paused delivery is kept, opens no attempt and resumes with its job",
         ctx do
      ks = Relay.Id.generate()
      assert {:ok, :paused} = Delivery.pause(ctx.scope, ctx.delivery_id, "killswitch.tenant", ks)

      assert {:ok, :already_paused} =
               Delivery.pause(ctx.scope, ctx.delivery_id, "killswitch.tenant", ks)

      assert {:ok,
              %{
                "paused_at" => %DateTime{},
                "pause_rule_id" => "killswitch.tenant",
                "pause_kill_switch_id" => ^ks,
                "failure_kind" => nil
              }} =
               Delivery.delivery(ctx.scope, ctx.delivery_id)

      assert {:ok, {:delivery_paused, nil}} =
               Delivery.open_attempt(ctx.scope, %{
                 id: Relay.Id.generate(),
                 delivery_id: ctx.delivery_id
               })

      job =
        SendWorker.new(%{"delivery_id" => Relay.Id.to_string(ctx.delivery_id), "resumed" => true})

      assert {:ok, :resumed} =
               Delivery.resume(
                 ctx.scope,
                 ctx.delivery_id,
                 "lattice:send:1",
                 "killswitch.released",
                 job
               )

      assert {:ok, :not_paused} =
               Delivery.resume(
                 ctx.scope,
                 ctx.delivery_id,
                 "lattice:send:1",
                 "killswitch.released"
               )

      assert [[1]] =
               Repo.query!(
                 "SELECT count(*)::int FROM relay_queue.oban_jobs WHERE args->>'delivery_id' = $1 AND args ? 'resumed'",
                 [Relay.Id.to_string(ctx.delivery_id)]
               ).rows

      assert {:ok, %{"paused_at" => nil, "pause_rule_id" => nil}} =
               Delivery.delivery(ctx.scope, ctx.delivery_id)

      assert {:ok, {:opened, 1}} =
               Delivery.open_attempt(ctx.scope, %{
                 id: Relay.Id.generate(),
                 delivery_id: ctx.delivery_id
               })

      assert ["delivery.queued", "delivery.paused", "delivery.resumed"] =
               events(ctx.scope, ctx.delivery_id)

      assert {:ok, []} = Delivery.rebuild_projection(ctx.scope, ctx.delivery_id)
    end

    test "TN-40: cancelling a paused delivery keeps its pause and fails it as cancelled", ctx do
      {:ok, :paused} = Delivery.pause(ctx.scope, ctx.delivery_id, "killswitch.tenant", nil)

      {:ok, :cancelled} =
        Delivery.cancel_delivery(
          ctx.scope,
          ctx.delivery_id,
          "killswitch.bulk_cancel:x",
          TenantFixture.digest(),
          actor()
        )

      assert {:ok, %{"paused_at" => %DateTime{}, "failure_kind" => "cancelled"}} =
               Delivery.delivery(ctx.scope, ctx.delivery_id)

      assert {:ok, :already_terminal} =
               Delivery.resume(
                 ctx.scope,
                 ctx.delivery_id,
                 "lattice:send:1",
                 "killswitch.released"
               )

      assert {:ok, :already_terminal} =
               Delivery.pause(ctx.scope, ctx.delivery_id, "killswitch.tenant", nil)

      assert {:ok, []} = Delivery.rebuild_projection(ctx.scope, ctx.delivery_id)
    end

    test "TN-40: a pause needs its rule", ctx do
      assert_raise Postgrex.Error, ~r/invalid_argument/, fn ->
        Delivery.pause(ctx.scope, ctx.delivery_id, nil, nil)
      end
    end
  end

  describe "T-34 (3) hold" do
    test "T-34 (3): a hold is only a ledger event", ctx do
      until = DateTime.add(DateTime.utc_now(), 60, :second)
      assert {:ok, :held} = Delivery.hold(ctx.scope, ctx.delivery_id, "load_shed.l2", until)
      assert "delivery.held" in events(ctx.scope, ctx.delivery_id)
      assert {:ok, %{result: :sendable}} = Delivery.gate(ctx.scope, ctx.delivery_id)
      assert {:ok, []} = Delivery.rebuild_projection(ctx.scope, ctx.delivery_id)

      assert {:ok, :not_found} =
               Delivery.hold(ctx.scope, Relay.Id.generate(), "load_shed.l2", until)
    end
  end
end
