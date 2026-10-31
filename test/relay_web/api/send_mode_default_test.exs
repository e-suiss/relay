defmodule RelayWeb.Api.SendModeDefaultTest do
  use Relay.DataCase, async: false

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")
    %{tenant: tenant, scope: tenant.live, token: token}
  end

  defp put_mode(scope, mode) do
    attrs = %{category: nil, channel: nil, mode: mode}
    {:ok, _row} = Relay.Operators.Admin.set_send_mode(scope, attrs, TenantFixture.actor(), nil)
    :ok
  end

  defp deliveries(token) do
    body = %{
      "workflow" => "order-shipped",
      "to" => [%{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}],
      "data" => %{"order" => "A-1"}
    }

    accepted = F.body(F.request(:post, "/v1/events", token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    F.body(F.request(:get, path, token), 200)["data"]
  end

  describe "OP-51 installation default" do
    test "OP-51: without a tenant level the installation default decides", ctx do
      :ok = put_mode(Relay.Datasets.installation_scope(), "off")

      assert [%{"id" => delivery, "status" => "skipped", "reason" => "send_mode_off"}] =
               deliveries(ctx.token)

      assert F.delivery_jobs(delivery) == []
    end

    test "OP-51: a tenant level wins over the installation default", ctx do
      :ok = put_mode(Relay.Datasets.installation_scope(), "off")
      :ok = put_mode(ctx.scope, "live")

      assert [%{"id" => delivery, "status" => "queued"}] = deliveries(ctx.token)
      assert [%{"queue" => "l1"}] = F.delivery_jobs(delivery)
    end

    test "OP-51: an unset installation default is live", ctx do
      assert [%{"status" => "queued"}] = deliveries(ctx.token)
    end
  end
end
