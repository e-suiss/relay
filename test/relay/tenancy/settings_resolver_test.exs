defmodule Relay.Tenancy.SettingsResolverTest do
  use Relay.DataCase, async: false

  alias RelayTest.TenantFixture

  @key "default_timezone"

  setup do
    TenantFixture.as_role("relay_worker")
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, subtenant: TenantFixture.subtenant!(tenant.live)}
  end

  defp put(scope, subtenant_id, value, version \\ nil) do
    scope
    |> Relay.Tenancy.put_setting(
      %{
        subtenant_id: subtenant_id,
        key: @key,
        value: value,
        expected_version: version,
        record_digest: TenantFixture.digest()
      },
      TenantFixture.actor()
    )
    |> case do
      {:ok, result} -> result
      error -> error
    end
  end

  defp resolve(scope, subtenant_id) do
    {:ok, [{@key, value, source}]} =
      Relay.Tenancy.resolve_stored_settings(scope, subtenant_id, [@key])

    {value, source}
  end

  describe "TN-4 settings inheritance" do
    test "TN-4: a sub-tenant value wins over the tenant value", %{tenant: t, subtenant: s} do
      assert {:created, _} = put(t.live, nil, "Europe/Berlin")
      assert {:created, _} = put(t.live, s, "Europe/London")

      assert resolve(t.live, s) == {"Europe/London", :subtenant}
      assert resolve(t.live, nil) == {"Europe/Berlin", :tenant}
    end

    test "TN-4: a tenant change never overwrites a sub-tenant value", %{tenant: t, subtenant: s} do
      {:created, v1} = put(t.live, nil, "Europe/Berlin")
      {:created, _} = put(t.live, s, "Europe/London")
      assert {:updated, _} = put(t.live, nil, "Asia/Tokyo", v1)

      assert resolve(t.live, s) == {"Europe/London", :subtenant}
      assert resolve(t.live, nil) == {"Asia/Tokyo", :tenant}
    end

    test "TN-4: clearing a sub-tenant value falls back to the tenant", %{tenant: t, subtenant: s} do
      {:created, _} = put(t.live, nil, "Europe/Berlin")
      {:created, v1} = put(t.live, s, "Europe/London")
      assert {:cleared, _} = put(t.live, s, nil, v1)

      assert resolve(t.live, s) == {"Europe/Berlin", :tenant}
    end

    test "TN-4: an unset key falls back to the tenant default", %{tenant: t, subtenant: s} do
      assert {"Europe/Istanbul", :tenant_defaults} = resolve(t.live, s)
    end

    test "TN-4: a stale version and an unknown sub-tenant are results, not errors", %{tenant: t} do
      {:created, v1} = put(t.live, nil, "Europe/Berlin")
      assert {:version_conflict, _} = put(t.live, nil, "Asia/Tehran", v1 + 5)
      assert {:subtenant_not_found, _} = put(t.live, Relay.Id.generate(), "Europe/Paris")
    end

    test "TN-4: settings are per environment", %{tenant: t, subtenant: s} do
      {:created, _} = put(t.live, nil, "Europe/Berlin")
      TenantFixture.subtenant!(t.test, s)
      assert {"Europe/Istanbul", :tenant_defaults} = resolve(t.test, s)
    end
  end

  describe "TN-4 the setting key catalog" do
    test "TN-4: a key outside the catalog is refused before the database", %{tenant: t} do
      assert {:error, %Relay.Error{code: :unknown_setting}} =
               Relay.Tenancy.put_setting(
                 t.live,
                 %{
                   key: "digest.window_minutes",
                   value: 30,
                   record_digest: TenantFixture.digest()
                 },
                 TenantFixture.actor()
               )
    end

    test "TN-65: a time zone setting is checked and stored under its canonical name", %{
      tenant: t,
      subtenant: s
    } do
      assert {:error, %Relay.Error{code: :invalid_time_zone}} = put(t.live, s, "Etc/GMT-3")
      assert {:created, _} = put(t.live, s, "Turkey")
      assert resolve(t.live, s) == {"Europe/Istanbul", :subtenant}
    end
  end
end
