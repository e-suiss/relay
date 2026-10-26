defmodule Relay.Tenancy.KillSwitchDeadManTest do
  use Relay.SqlCase, async: false

  alias Relay.Tenancy.KillSwitch

  @operator %{kind: :installation_operator, ref: "ops@example"}

  defp counter(sums) do
    test = self()

    fn _scope, key, _params ->
      send(test, {:counted, key})
      sums
    end
  end

  setup do
    s = scenario!()
    %{scope: Relay.Scope.new!(s.tenant, :test), tenant: s.tenant}
  end

  defp records(tenant) do
    "active" = ctx(tenant)

    rows(
      "SELECT scope_kind, scope_ref, state, paused_until IS NULL, origin, expires_at, no_ttl_approval_ref, message_class, created_by_ref FROM relay.kill_switches WHERE status = 'active' AND origin = 'dead_man' ORDER BY scope_kind",
      []
    )
  end

  describe "TN-43 automatic pause" do
    test "TN-43: a volume ten times the baseline pauses the tenant without end and without class",
         %{scope: scope, tenant: tenant} do
      assert [%{result: :engaged, id: "ksw_" <> _}] =
               KillSwitch.record_attempt(scope, %{message_class: :marketing},
                 counter: counter({600, 0})
               )

      assert_received {:counted, "dms:tenant:tenant"}

      assert [
               [
                 "tenant",
                 nil,
                 "paused_until",
                 false,
                 "dead_man",
                 nil,
                 "TN-43",
                 nil,
                 "system:dead_man"
               ]
             ] =
               records(tenant)

      assert one(
               "SELECT count(*)::int FROM relay.kill_switches WHERE status = 'active' AND paused_until = 'infinity'"
             ) == 1
    end

    test "TN-43: campaign and workflow scopes are counted when the message carries them", %{
      scope: scope,
      tenant: tenant
    } do
      results =
        KillSwitch.record_attempt(
          scope,
          %{
            message_class: "transactional",
            campaign_id: "cmp-1",
            workflow_id: Relay.Id.generate()
          },
          counter: counter({100, 0})
        )

      assert results == []
      assert_received {:counted, "dms:tenant:tenant"}
      assert_received {:counted, "dms:campaign:cmp-1"}
      assert_received {:counted, "dms:workflow:" <> _}
      assert records(tenant) == []
    end

    test "TN-43: security messages are not counted and never trip the switch", %{scope: scope} do
      assert KillSwitch.record_attempt(scope, %{message_class: :security},
               counter: counter({10_000, 0})
             ) == []

      refute_received {:counted, _}
    end

    test "TN-43: a second trip of the same scope keeps the one automatic pause", %{
      scope: scope,
      tenant: tenant
    } do
      [%{result: :engaged, id: id}] =
        KillSwitch.record_attempt(scope, %{message_class: :marketing}, counter: counter({600, 0}))

      assert [%{result: :dead_man_active, id: ^id}] =
               KillSwitch.record_attempt(scope, %{message_class: :marketing},
                 counter: counter({700, 0})
               )

      assert length(records(tenant)) == 1
    end

    test "TN-43: the automatic pause does not stop security and opening it is a human decision with approval",
         %{scope: scope, tenant: tenant} do
      [%{id: id}] =
        KillSwitch.record_attempt(scope, %{message_class: :marketing}, counter: counter({600, 0}))

      {:ok, generation, records} = KillSwitch.Store.snapshot()
      snapshot = KillSwitch.Snapshot.new(generation, records)

      message = %{
        tenant_id: tenant,
        environment: :test,
        channel: "sms",
        notification_id: Relay.Id.generate()
      }

      assert {:pause, _, "killswitch.paused_until"} =
               KillSwitch.evaluate(
                 snapshot,
                 Map.put(message, :message_class, "marketing"),
                 DateTime.utc_now()
               )

      assert :allow =
               KillSwitch.evaluate(
                 snapshot,
                 Map.put(message, :message_class, "security"),
                 DateTime.utc_now()
               )

      assert {:error, :relax_approval_required} =
               KillSwitch.release(id, %{reason: "checked"}, @operator)

      assert {:ok, %{result: :released}} =
               KillSwitch.release(id, %{reason: "checked", relax_approval: "CAB-7"}, @operator)
    end

    test "TN-43: the counter is the per-minute ring of the rate limiter", %{scope: scope} do
      assert KillSwitch.record_attempt(scope, %{message_class: :marketing}) == []
    end
  end
end
