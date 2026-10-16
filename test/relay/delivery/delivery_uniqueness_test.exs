defmodule Relay.Delivery.DeliveryUniquenessTest do
  use Relay.DataCase, async: false

  alias Relay.Ingest.Store
  alias RelayTest.TenantFixture

  setup do
    TenantFixture.as_role("relay_worker")
    tenant = TenantFixture.tenant!()
    keys = TenantFixture.keys!(tenant.live)
    recipient = TenantFixture.recipient!(tenant.live, keys)

    {:ok, {:created, notification_id}} =
      Store.in_scope(tenant.live, fn _ ->
        Store.notification_accept(TenantFixture.notification(recipient))
      end)

    %{scope: tenant.live, notification_id: notification_id}
  end

  defp open(scope, notification_id, delivery) do
    {:ok, result} =
      Store.in_scope(scope, fn _ -> Store.delivery_open(notification_id, delivery) end)

    result
  end

  describe "C-30 C-82 one delivery per notification, channel and target" do
    test "C-30: opening the same channel and target again returns the existing delivery", ctx do
      target = :crypto.strong_rand_bytes(32)
      first = TenantFixture.delivery(target_key: target)
      assert {:opened, id} = open(ctx.scope, ctx.notification_id, first)

      assert {:exists, ^id} =
               open(ctx.scope, ctx.notification_id, TenantFixture.delivery(target_key: target))
    end

    test "C-82: two devices of one recipient get two push deliveries", ctx do
      for _ <- 1..2 do
        device = TenantFixture.delivery(channel: :push, target_kind: :device)
        assert {:opened, _} = open(ctx.scope, ctx.notification_id, device)
      end
    end

    test "C-30: a fallback is a new delivery pointing at the one it replaces", ctx do
      {:opened, primary} =
        open(
          ctx.scope,
          ctx.notification_id,
          TenantFixture.delivery(channel: :push, target_kind: :device)
        )

      fallback = TenantFixture.delivery(channel: :sms, fallback_of: primary)
      assert {:opened, id} = open(ctx.scope, ctx.notification_id, fallback)
      assert id != primary
    end

    test "C-30: a fallback of an unknown delivery is refused", ctx do
      assert {:fallback_invalid, nil} =
               open(
                 ctx.scope,
                 ctx.notification_id,
                 TenantFixture.delivery(fallback_of: Relay.Id.generate())
               )
    end

    test "TN-15: another tenant's notification is not found", ctx do
      other = TenantFixture.tenant!()

      assert {:notification_not_found, nil} =
               open(other.live, ctx.notification_id, TenantFixture.delivery())
    end
  end
end
