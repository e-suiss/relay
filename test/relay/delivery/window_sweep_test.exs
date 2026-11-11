defmodule Relay.Delivery.WindowSweepTest do
  use Relay.DataCase, async: false

  alias Relay.Channels.Live
  alias Relay.Datasets
  alias Relay.Delivery.WindowSweep
  alias Relay.DeliveryWindows
  alias Relay.Platform.VirtualClock
  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture

  @hour 3_600_000

  defp forget do
    for name <- ["delivery_windows", "channel_event_evidence"],
        do: Datasets.Cache.invalidate(Datasets.Cache, {Datasets.installation_scope(), name})

    :ok
  end

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)
    :ok
  end

  defp accepted!(scope, id, ago_ms) do
    attempt = DeliveryFixture.started_attempt!(scope, id)

    {:ok, entry} =
      Relay.Delivery.ledger_entry(
        id: Relay.Id.generate(),
        delivery_id: id,
        attempt_no: attempt,
        actor: :provider_api,
        provider: "fake",
        event_type: "attempt.succeeded",
        occurred_at: DateTime.add(Relay.Clock.utc_now(), -ago_ms, :millisecond),
        delivery_rank: :accepted
      )

    assert {:ok, {:applied, :accepted, _}} = Relay.Delivery.append_ledger(scope, entry)
    attempt
  end

  defp delivered!(scope, id, attempt) do
    {:ok, entry} =
      Relay.Delivery.ledger_entry(
        id: Relay.Id.generate(),
        delivery_id: id,
        attempt_no: attempt,
        actor: :provider_webhook,
        provider: "fake",
        event_type: "provider.reported",
        occurred_at: Relay.Clock.utc_now(),
        delivery_rank: :delivered
      )

    {:ok, {result, _rank, _version}} = Relay.Delivery.append_ledger(scope, entry)
    result
  end

  defp delivery(scope, id) do
    {:ok, delivery} = Relay.Delivery.delivery(scope, id)
    delivery
  end

  defp events(scope, id) do
    {:ok, ledger} = Relay.Delivery.ledger(scope, id)
    Enum.filter(ledger, &String.starts_with?(&1["event_type"], "delivery.unknown"))
  end

  defp sms!(opts \\ []),
    do: DeliveryFixture.sendable!(Keyword.merge([delivery: [channel: :sms]], opts))

  describe "DS-18 INV-5 the two-stage DLR window" do
    test "DS-18, INV-5: an SMS without a definite event is unknown_pending after a while" do
      %{scope: scope, delivery_id: id} = sms!()
      accepted!(scope, id, 7 * @hour)

      assert :ok = WindowSweep.run_due(scope)
      assert %{"delivery_rank" => 1, "window_stage" => 1} = delivery(scope, id)

      assert [%{"event_type" => "delivery.unknown_pending", "actor" => "relay"}] =
               events(scope, id)

      assert :ok = WindowSweep.run_due(scope)
      assert length(events(scope, id)) == 1
      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end

    test "DS-18, DS-19: after the long window it is unknown, through both stages" do
      %{scope: scope, delivery_id: id} = sms!()
      accepted!(scope, id, 73 * @hour)

      assert WindowSweep.sweep() >= 1
      assert %{"delivery_rank" => 1, "window_stage" => 2} = delivery(scope, id)

      assert Enum.map(events(scope, id), & &1["event_type"]) ==
               ["delivery.unknown_pending", "delivery.unknown"]

      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end

    test "DS-18: a delivery inside its short window, or with a definite event, is left alone" do
      %{scope: scope, delivery_id: fresh} = sms!()
      accepted!(scope, fresh, 5 * @hour)

      %{scope: other, delivery_id: done} = sms!()
      attempt = accepted!(other, done, 7 * @hour)
      assert delivered!(other, done, attempt) == :applied

      assert :ok = WindowSweep.run_due(scope)
      assert :ok = WindowSweep.run_due(other)
      assert %{"delivery_rank" => 1, "window_stage" => 0} = delivery(scope, fresh)
      assert %{"delivery_rank" => 2, "window_stage" => 0} = delivery(other, done)
    end

    test "DS-13, CH-32: a push delivery the provider accepted never falls to unknown" do
      %{scope: scope, delivery_id: id} =
        DeliveryFixture.sendable!(delivery: [channel: :push, target_kind: :device])

      accepted!(scope, id, 30 * 24 * @hour)

      assert :ok = WindowSweep.run_due(scope)
      assert %{"delivery_rank" => 1, "window_stage" => 0} = delivery(scope, id)
      assert events(scope, id) == []
    end
  end

  describe "DS-20 INV-9 late definite events" do
    test "DS-20, INV-9, DS-21: a late delivered lifts unknown and nothing is resent" do
      %{scope: scope, delivery_id: id} = sms!()
      attempt = accepted!(scope, id, 80 * @hour)
      assert :ok = WindowSweep.run_due(scope)
      assert %{"window_stage" => 2, "attempt_count" => 1} = delivery(scope, id)

      assert delivered!(scope, id, attempt) == :applied
      assert %{"delivery_rank" => 2, "attempt_count" => 1} = delivery(scope, id)
      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end

    test "DS-20, DS-17: a late definite failure turns unknown into failed" do
      %{scope: scope, delivery_id: id} = sms!()
      accepted!(scope, id, 80 * @hour)
      assert :ok = WindowSweep.run_due(scope)

      event = %{delivery_id: id, provider: "fake", channel: "sms", event_code: "bounced"}
      assert {:ok, %{result: :applied}} = Live.record_event(scope, event)
      assert %{"failure_kind" => "bounced", "window_stage" => 2} = delivery(scope, id)
      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end
  end

  describe "DS-50 tenant windows" do
    test "DS-50, DS-46: a tenant version adjusts its windows, bounded by the defaults" do
      %{scope: scope, delivery_id: early} = sms!()

      content = %{
        "source_ref" => "test",
        "windows" => [
          %{"channel" => "sms", "provider" => nil, "short_ms" => @hour, "long_ms" => 72 * @hour}
        ]
      }

      actor = TenantFixture.actor()

      assert {:ok, {:published, version, _no}} =
               Datasets.publish(scope, "delivery_windows", content, actor, source_ref: "test")

      assert {:ok, :activated} =
               Datasets.activate(scope, "delivery_windows", version, :operator, actor)

      assert {:ok, windows} = WindowSweep.windows(scope)
      assert %{"short_ms" => short} = DeliveryWindows.window(windows, "sms", nil)
      assert short == 3 * @hour

      accepted!(scope, early, 4 * @hour)
      assert :ok = WindowSweep.run_due(scope)
      assert %{"window_stage" => 1} = delivery(scope, early)
    end
  end

  describe "DS-23 test plane simulation" do
    test "DS-23, TN-8: the virtual clock moves a test delivery through both windows" do
      %{scope: scope, delivery_id: id} = sms!(environment: :test)
      _attempt = DeliveryFixture.started_attempt!(scope, id)
      event = %{delivery_id: id, provider: "fake", channel: "sms", event_code: "accepted"}
      assert {:ok, %{result: :applied}} = Live.record_event(scope, event)

      advance = fn ms ->
        assert {:ok, {:advanced, _, _}} =
                 VirtualClock.advance(scope, ms, TenantFixture.digest(), TenantFixture.actor())

        assert :ok = WindowSweep.run_due(scope)
        delivery(scope, id)["window_stage"]
      end

      assert advance.(5 * @hour) == 0
      assert advance.(2 * @hour) == 1
      assert advance.(66 * @hour) == 2

      late = %{event | event_code: "delivered"}
      assert {:ok, %{result: :applied}} = Live.record_event(scope, late)
      assert %{"delivery_rank" => 2, "late_event_count" => 0} = delivery(scope, id)

      assert {:ok, %{result: :stale_ignored}} = Live.record_event(scope, late)
      assert %{"delivery_rank" => 2, "late_event_count" => 1} = delivery(scope, id)
      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end
  end
end
