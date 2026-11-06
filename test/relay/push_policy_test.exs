defmodule Relay.PushPolicyTest do
  use Relay.DataCase, async: true

  alias Relay.Operators.Admin
  alias Relay.PushPolicy
  alias Relay.Repo
  alias RelayTest.TenantFixture

  @day 86_400_000

  defp audit(scope, action) do
    now = DateTime.utc_now()
    actor = TenantFixture.actor()

    {:ok, rows} =
      Repo.in_scope(scope, fn _status ->
        Repo.call!(
          "relay_fn.audit_query",
          [DateTime.add(now, -3_600), DateTime.add(now, 3_600), action, nil, 1_000] ++
            [TenantFixture.digest() | Relay.Actor.params(actor)]
        )
      end)

    Enum.reject(rows, &(&1["actor_ref"] == "relay-test"))
  end

  defp outbox(scope, type) do
    {:ok, rows} =
      Repo.in_scope(scope, fn _status ->
        Repo.scoped_query!(
          "SELECT payload FROM relay.outbox_events WHERE event_type = $1",
          [type]
        ).rows
      end)

    for [payload] <- rows, do: payload
  end

  defp open!(tenant) do
    value = %{
      "templates" => ["flight-cancelled"],
      "entitlements" => [%{"platform" => "apns", "reference" => "apple-critical-1"}]
    }

    {:ok, _row} =
      Admin.set_critical_interruption(
        tenant.id,
        value,
        "entitlement shown",
        TenantFixture.actor(),
        "stepup-1"
      )
  end

  describe "CH-20 TN-23 critical opening" do
    test "CH-20: critical is closed by default and opened only by the stored opening" do
      tenant = TenantFixture.tenant!()

      assert {:ok, %{enabled: false, templates: []} = closed} =
               PushPolicy.critical_opening(tenant.live)

      refute PushPolicy.critical_template?(closed, "flight-cancelled")

      open!(tenant)

      for scope <- [tenant.live, tenant.test] do
        assert {:ok, %{enabled: true} = opening} = PushPolicy.critical_opening(scope)
        assert opening.entitlements == [%{platform: "apns", reference: "apple-critical-1"}]
        assert PushPolicy.critical_template?(opening, "flight-cancelled")
        refute PushPolicy.critical_template?(opening, "order-shipped")
      end

      {:ok, _row} =
        Admin.set_critical_interruption(tenant.id, nil, "revoked", TenantFixture.actor(), "s-2")

      assert {:ok, %{enabled: false}} = PushPolicy.critical_opening(tenant.test)
    end

    test "CH-20, TN-47: every critical delivery is audited" do
      tenant = TenantFixture.tenant!()
      delivery_id = Relay.Id.generate()

      assert :ok =
               PushPolicy.record_critical_use(tenant.test, %{
                 delivery_id: delivery_id,
                 template_key: "flight-cancelled"
               })

      assert [row] = audit(tenant.test, "push_critical.used")
      assert row["target_id"] == Relay.Id.to_string(delivery_id)
    end
  end

  describe "CH-22 high priority ratio" do
    test "CH-22: the threshold needs volume and a share over the policy default" do
      assert %{ratio_bp: 2_000, min_volume: 1_000, window_ms: @day} = PushPolicy.threshold()
      refute PushPolicy.over?(999, 999)
      refute PushPolicy.over?(200, 1_000)
      assert PushPolicy.over?(201, 1_000)
    end

    test "CH-22: crossing the threshold warns the tenant once and audits the warning" do
      scope = TenantFixture.tenant!().test

      assert {:ok, :counted} = PushPolicy.record_priority(scope, false)
      {:ok, _} = Relay.Platform.rate_counter(scope, "push_priority:total", @day, :incr, 998)
      {:ok, _} = Relay.Platform.rate_counter(scope, "push_priority:high", @day, :incr, 998)

      assert {:ok, :warned} = PushPolicy.record_priority(scope, true)
      assert {:ok, :counted} = PushPolicy.record_priority(scope, true)

      assert [%{"threshold_bp" => 2_000, "total" => 1_000, "high" => 999}] =
               outbox(scope, "push_priority.threshold_reached")

      assert [_row] = audit(scope, "push_priority.threshold_reached")
    end
  end
end
