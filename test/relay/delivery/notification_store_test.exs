defmodule Relay.Delivery.NotificationStoreTest do
  use Relay.DataCase, async: false

  alias Relay.Ingest.Store
  alias Relay.Repo
  alias RelayTest.TenantFixture

  setup do
    TenantFixture.as_role("relay_worker")
    tenant = TenantFixture.tenant!()
    keys = TenantFixture.keys!(tenant.live)

    %{
      scope: tenant.live,
      recipient: TenantFixture.recipient!(tenant.live, keys),
      other: TenantFixture.recipient!(tenant.live, keys)
    }
  end

  defp accept(scope, notification) do
    {:ok, result} = Store.in_scope(scope, fn _ -> Store.notification_accept(notification) end)
    result
  end

  describe "API-16 C-29 C-80 notification dedup" do
    test "API-16: the same dedup key and recipient return the first notification and count the repeat",
         ctx do
      first = TenantFixture.notification(ctx.recipient, dedup_key: "invoice-7")
      assert {:created, id} = accept(ctx.scope, first)

      for _ <- 1..2 do
        repeat = TenantFixture.notification(ctx.recipient, dedup_key: "invoice-7")
        assert {:duplicate, ^id} = accept(ctx.scope, repeat)
      end

      assert {:ok, %{"duplicate_count" => 2}} = Relay.Delivery.notification(ctx.scope, id)
    end

    test "API-16: the dedup key is unique per recipient", ctx do
      assert {:created, a} =
               accept(ctx.scope, TenantFixture.notification(ctx.recipient, dedup_key: "k-1"))

      assert {:created, b} =
               accept(ctx.scope, TenantFixture.notification(ctx.other, dedup_key: "k-1"))

      assert a != b
    end

    test "C-80: the dedup key does not depend on the channel", ctx do
      email =
        TenantFixture.notification(ctx.recipient,
          dedup_key: "k-2",
          deliveries: [TenantFixture.delivery(channel: :email)]
        )

      sms =
        TenantFixture.notification(ctx.recipient,
          dedup_key: "k-2",
          deliveries: [TenantFixture.delivery(channel: :sms)]
        )

      assert {:created, id} = accept(ctx.scope, email)
      assert {:duplicate, ^id} = accept(ctx.scope, sms)
    end

    test "C-29: the dedup key has no update path", ctx do
      {:created, id} =
        accept(ctx.scope, TenantFixture.notification(ctx.recipient, dedup_key: "k-3"))

      assert {:error, %Postgrex.Error{}} =
               Repo.in_scope(ctx.scope, fn _ ->
                 case Repo.query(
                        "UPDATE relay.notifications SET dedup_key = 'k-4' WHERE id = $1",
                        [id]
                      ) do
                   {:ok, result} -> result
                   {:error, error} -> Repo.rollback(error)
                 end
               end)
    end
  end

  describe "OP-2 notifications and deliveries are separate records" do
    test "OP-2: the uniqueness tables are not partitioned" do
      %{rows: rows} =
        Repo.query!(
          "SELECT relname, relkind FROM pg_class WHERE relnamespace = 'relay'::regnamespace AND relname IN ('notifications', 'deliveries', 'webhook_receipts')",
          []
        )

      assert Enum.sort(rows) == [
               ["deliveries", "r"],
               ["notifications", "r"],
               ["webhook_receipts", "r"]
             ]
    end

    test "OP-2: a skipped delivery still opens a delivery row with its rule", ctx do
      skip = TenantFixture.delivery(decision: :skip)

      {:created, id} =
        accept(ctx.scope, TenantFixture.notification(ctx.recipient, deliveries: [skip]))

      assert {:ok, {:opened, delivery_id}} =
               Store.in_scope(ctx.scope, fn _ -> Store.delivery_open(id, skip) end)

      assert {:ok,
              %{"decision" => "skip", "decision_rule_id" => "TEST-1", "failure_kind" => "skipped"}} =
               Relay.Delivery.delivery(ctx.scope, delivery_id)

      assert {:ok, [%{"event_type" => "delivery.skipped"}]} =
               Relay.Delivery.ledger(ctx.scope, delivery_id)
    end
  end
end
