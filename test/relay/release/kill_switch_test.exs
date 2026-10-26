defmodule Relay.Release.KillSwitchTest do
  use Relay.SqlCase, async: false

  alias Relay.Release.KillSwitch

  setup do
    s = scenario!()
    %{s: s, tenant: Relay.ExternalId.encode("ten", s.tenant)}
  end

  defp engage!(opts) do
    {:ok, %{result: :engaged, id: id}} =
      KillSwitch.engage(
        Keyword.merge([operator: "ops@example", reason: "incident 9", ttl: "2h"], opts)
      )

    id
  end

  describe "TN-70 release command surface" do
    test "TN-70: a call needs the operator name, a reason and a TTL or a no-TTL approval", %{
      tenant: tenant
    } do
      base = [scope: :tenant, tenant: tenant, environment: :test]

      assert {:error, :operator_required} = KillSwitch.engage(base ++ [reason: "r", ttl: "1h"])

      assert {:error, :operator_required} =
               KillSwitch.engage(base ++ [operator: " ", reason: "r", ttl: "1h"])

      assert {:error, :reason_required} =
               KillSwitch.engage(base ++ [operator: "ops", reason: "", ttl: "1h"])

      assert {:error, :no_ttl_approval_required} =
               KillSwitch.engage(base ++ [operator: "ops", reason: "r"])

      assert {:error, :invalid_ttl} =
               KillSwitch.engage(base ++ [operator: "ops", reason: "r", ttl: "soon"])

      assert {:ok, %{result: :engaged}} =
               KillSwitch.engage(base ++ [operator: "ops", reason: "r", no_ttl_approval: "CAB-1"])

      assert {:ok, %{result: :engaged}} =
               KillSwitch.engage(base ++ [operator: "ops", reason: "r", ttl: "30m"])
    end

    test "TN-70: the tenant scope needs a tenant and an environment; Access identifiers are not resolved yet",
         %{tenant: tenant} do
      opts = [operator: "ops", reason: "r", ttl: "1h", scope: :tenant]
      assert {:error, :tenant_required} = KillSwitch.engage(opts)
      assert {:error, :environment_required} = KillSwitch.engage(opts ++ [tenant: tenant])
      assert {:error, :tenant_lookup_unsupported} = KillSwitch.engage(opts ++ [tenant: "acc_1"])
      assert {:error, :invalid_scope} = KillSwitch.engage(Keyword.put(opts, :scope, :galaxy))
    end

    test "TN-70: releasing relaxes and needs confirm_relax", %{tenant: tenant} do
      id = engage!(scope: :tenant, tenant: tenant, environment: :test)

      assert {:error, :relax_approval_required} =
               KillSwitch.release(id, operator: "ops", reason: "fixed")

      assert {:ok, %{result: :released}} =
               KillSwitch.release(id, operator: "ops", reason: "fixed", confirm_relax: "CAB-2")

      assert {:error, :not_found} =
               KillSwitch.release(id, operator: "ops", reason: "fixed", confirm_relax: "CAB-2")
    end

    test "TN-70: a relaxing replacement needs confirm_relax, a tightening one does not", %{
      tenant: tenant
    } do
      id = engage!(scope: :tenant, tenant: tenant, environment: :test, state: {:canary, 20})

      assert {:error, :relax_approval_required} =
               KillSwitch.replace(id,
                 operator: "ops",
                 reason: "wider",
                 state: {:canary, 50},
                 ttl: "3h"
               )

      assert {:ok, %{result: :replaced, id: tighter}} =
               KillSwitch.replace(id, operator: "ops", reason: "stop", state: :off, ttl: "3h")

      assert {:ok, %{result: :replaced}} =
               KillSwitch.replace(tighter,
                 operator: "ops",
                 reason: "done",
                 state: :on,
                 ttl: "3h",
                 confirm_relax: "CAB-3"
               )
    end

    test "TN-70: resume is refused in stage 2", %{s: s, tenant: tenant} do
      id = engage!(scope: :tenant, tenant: tenant, environment: :test)
      delivery = delivery!(s.notification)
      {:ok, ksw} = Relay.ExternalId.decode(id, ["ksw"])
      "active" = ctx(s.tenant)
      "paused" = one("SELECT relay_fn.delivery_pause($1, 'killswitch.off', $2)", [delivery, ksw])

      assert {:error, :relax_approval_required} =
               KillSwitch.resume(id, operator: "ops", reason: "go")

      assert {:error, :policy_lattice_unavailable} =
               KillSwitch.resume(id, operator: "ops", reason: "go", confirm_relax: "CAB-4")
    end

    test "TN-70: bulk cancel runs", %{s: s, tenant: tenant} do
      id = engage!(scope: :tenant, tenant: tenant, environment: :test)
      delivery = delivery!(s.notification)
      {:ok, ksw} = Relay.ExternalId.decode(id, ["ksw"])
      "active" = ctx(s.tenant)
      "paused" = one("SELECT relay_fn.delivery_pause($1, 'killswitch.off', $2)", [delivery, ksw])

      assert {:error, :reason_required} = KillSwitch.bulk_cancel(id, operator: "ops")

      assert {:ok, %{cancelled: 1}} =
               KillSwitch.bulk_cancel(id, operator: "ops", reason: "wrong audience")
    end

    test "TN-70: list and show return the records with external identifiers", %{tenant: tenant} do
      id = engage!(scope: :tenant, tenant: tenant, environment: :test, channel: :sms)
      platform = engage!(scope: :platform, message_class: :marketing)

      assert {:ok, %{id: ^id, scope: :tenant, channel: "sms", state: :off}} = KillSwitch.show(id)

      assert {:ok, %{kill_switches: listed}} =
               KillSwitch.list(tenant: tenant, environment: :test)

      assert Enum.sort(Enum.map(listed, & &1.id)) == Enum.sort([id, platform])

      assert {:ok, %{kill_switches: all}} = KillSwitch.list()
      assert id in Enum.map(all, & &1.id)
      assert {:error, :not_found} = KillSwitch.show(Relay.ExternalId.encode("ksw", id()))
      assert {:error, :invalid_id} = KillSwitch.show("nope")
    end

    test "TN-42: stopping security from the command needs the security approval", %{
      tenant: tenant
    } do
      opts = [scope: :tenant, tenant: tenant, environment: :test, message_class: :security]

      assert {:error, :security_approval_required} =
               KillSwitch.engage(opts ++ [operator: "ops", reason: "r", ttl: "1h"])

      assert {:ok, %{result: :engaged}} =
               KillSwitch.engage(
                 opts ++ [operator: "ops", reason: "r", ttl: "1h", security_approval: "SEC-2"]
               )
    end
  end
end
