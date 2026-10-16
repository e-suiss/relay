defmodule Relay.Tenancy.SettingsResolverTest do
  use Relay.DataCase, async: false

  alias RelayTest.TenantFixture

  @key "digest.window_minutes"

  setup do
    TenantFixture.as_role("relay_worker")
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, subtenant: TenantFixture.subtenant!(tenant.live)}
  end

  defp put(scope, subtenant_id, value, version \\ nil) do
    {:ok, result} =
      Relay.Tenancy.put_setting(
        scope,
        %{
          subtenant_id: subtenant_id,
          key: @key,
          value: value,
          expected_version: version,
          record_digest: TenantFixture.digest()
        },
        TenantFixture.actor()
      )

    result
  end

  defp resolve(scope, subtenant_id) do
    {:ok, [{@key, value, source}]} =
      Relay.Tenancy.resolve_stored_settings(scope, subtenant_id, [@key])

    {value, source}
  end

  describe "TN-4 settings inheritance" do
    test "TN-4: a sub-tenant value wins over the tenant value", %{tenant: t, subtenant: s} do
      assert {:created, _} = put(t.live, nil, 30)
      assert {:created, _} = put(t.live, s, 10)

      assert resolve(t.live, s) == {10, :subtenant}
      assert resolve(t.live, nil) == {30, :tenant}
    end

    test "TN-4: a tenant change never overwrites a sub-tenant value", %{tenant: t, subtenant: s} do
      {:created, v1} = put(t.live, nil, 30)
      {:created, _} = put(t.live, s, 10)
      assert {:updated, _} = put(t.live, nil, 60, v1)

      assert resolve(t.live, s) == {10, :subtenant}
      assert resolve(t.live, nil) == {60, :tenant}
    end

    test "TN-4: clearing a sub-tenant value falls back to the tenant", %{tenant: t, subtenant: s} do
      {:created, _} = put(t.live, nil, 30)
      {:created, v1} = put(t.live, s, 10)
      assert {:cleared, _} = put(t.live, s, nil, v1)

      assert resolve(t.live, s) == {30, :tenant}
    end

    test "TN-4: an unset key resolves to nothing", %{tenant: t, subtenant: s} do
      assert {nil, :none} = resolve(t.live, s)
    end

    test "TN-4: a stale version and an unknown sub-tenant are results, not errors", %{tenant: t} do
      {:created, v1} = put(t.live, nil, 30)
      assert {:version_conflict, _} = put(t.live, nil, 31, v1 + 5)
      assert {:subtenant_not_found, _} = put(t.live, Relay.Id.generate(), 1)
    end

    test "TN-4: settings are per environment", %{tenant: t, subtenant: s} do
      {:created, _} = put(t.live, nil, 30)
      TenantFixture.subtenant!(t.test, s)
      assert {nil, :none} = resolve(t.test, s)
    end
  end
end
