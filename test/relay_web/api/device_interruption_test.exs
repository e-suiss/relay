defmodule RelayWeb.Api.DeviceInterruptionTest do
  use Relay.DataCase, async: false

  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.RealtimeFixture
  alias RelayTest.TenantFixture

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    scope = tenant.live
    app = FakeAccess.client!(scope, ["read"])
    ctx = %{scope: scope, access_tenant: tenant.attrs.access_tenant_id, app: app}
    {token, id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
    Map.merge(ctx, %{subscriber_token: token, id: id})
  end

  describe "CH-65 interruption permissions of a device" do
    test "CH-65: a registration records the device's interruption permissions", ctx do
      permissions = %{"critical_alerts" => "denied", "time_sensitive" => "granted"}

      device = %{
        "platform" => "apns",
        "token" => String.duplicate("ab", 32),
        "app" => "com.example.app",
        "apns_environment" => "production",
        "permission" => "granted",
        "interruption_permissions" => permissions
      }

      body = F.body(F.request(:post, "/v1/subscriber/devices", ctx.subscriber_token, device), 201)
      assert body["interruption_permissions"] == permissions

      {:ok, [target]} =
        Relay.Devices.Store.in_scope(ctx.scope, fn _status -> Relay.Devices.current(ctx.id) end)

      assert target["interruption_permissions"] == permissions

      again = Map.put(device, "interruption_permissions", %{"critical_alerts" => "granted"})
      body = F.body(F.request(:post, "/v1/subscriber/devices", ctx.subscriber_token, again), 200)
      assert body["interruption_permissions"] == %{"critical_alerts" => "granted"}
    end
  end
end
