defmodule Relay.Ingest.AcceptTransactionTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.TenantFixture

  setup do
    TenantFixture.as_role("relay_worker")
    tenant = TenantFixture.tenant!()
    keys = TenantFixture.keys!(tenant.live)
    %{scope: tenant.live, keys: keys, recipient: TenantFixture.recipient!(tenant.live, keys)}
  end

  defp jobs_for(delivery_id) do
    Repo.query!(
      "SELECT args FROM relay_queue.oban_jobs WHERE args->>'delivery_id' = $1",
      [Ecto.UUID.load!(delivery_id)]
    ).rows
    |> List.flatten()
  end

  defp outbox_rows(scope, id) do
    {:ok, rows} =
      Repo.in_scope(scope, fn _ ->
        Repo.scoped_query!(
          "SELECT tenant_id, environment, state FROM relay.outbox_events WHERE id = $1",
          [id]
        ).rows
      end)

    rows
  end

  defp event(stream_key \\ nil) do
    %{
      id: Relay.Id.generate(),
      event_type: "notification.accepted",
      stream_key: stream_key || "events:" <> TenantFixture.random(),
      payload: %{"kind" => "accepted"}
    }
  end

  describe "OP-7 T-57 record, job and outbox in one transaction" do
    test "T-57: an accepted notification has its deliveries, its send job and its outbox event",
         ctx do
      send = TenantFixture.delivery()
      skip = TenantFixture.delivery(decision: :skip, channel: :sms)
      notification = TenantFixture.notification(ctx.recipient, deliveries: [send, skip])
      outbox = event()

      assert {:ok, outcome} =
               Relay.Ingest.accept(
                 ctx.scope,
                 TenantFixture.accept_request([notification],
                   outbox: [outbox],
                   data_key: ctx.keys.data
                 )
               )

      assert [%{id: id, result: :created, deliveries: deliveries}] = outcome.notifications
      assert id == notification.id
      assert Enum.map(deliveries, & &1.result) == [:opened, :opened]
      assert outcome.stored == :stored
      assert [%{stream_key: _, seq: seq}] = outcome.outbox
      assert is_integer(seq)

      assert {:ok, %{"state" => "active"}} = Relay.Delivery.notification(ctx.scope, id)
      assert {:ok, %{"decision" => "skip"}} = Relay.Delivery.delivery(ctx.scope, skip.id)

      assert [args] = jobs_for(send.id)

      assert Map.keys(args) |> Enum.sort() ==
               ["delivery_id", "environment", "notification_id", "tenant_id"]

      assert jobs_for(skip.id) == []
      assert [[_, "live", "pending"]] = outbox_rows(ctx.scope, outbox.id)
    end

    test "T-57: a failure in any step leaves no notification, delivery, job or outbox row", ctx do
      send = TenantFixture.delivery()
      notification = TenantFixture.notification(ctx.recipient, deliveries: [send])
      broken = event("NOT A STREAM KEY")

      assert_raise Postgrex.Error, fn ->
        Relay.Ingest.accept(
          ctx.scope,
          TenantFixture.accept_request([notification], outbox: [broken], data_key: ctx.keys.data)
        )
      end

      assert {:ok, nil} = Relay.Delivery.notification(ctx.scope, notification.id)
      assert {:ok, nil} = Relay.Delivery.delivery(ctx.scope, send.id)
      assert jobs_for(send.id) == []
      assert outbox_rows(ctx.scope, broken.id) == []
    end

    test "INV-2: a failing response seal rolls the whole accept back", ctx do
      send = TenantFixture.delivery()
      notification = TenantFixture.notification(ctx.recipient, deliveries: [send])

      request =
        %{
          TenantFixture.accept_request([notification], data_key: ctx.keys.data)
          | seal: fn _ -> {:error, :sealing} end
        }

      assert {:error, %Relay.Error{code: :accept_failed}} =
               Relay.Ingest.accept(ctx.scope, request)

      assert {:ok, nil} = Relay.Delivery.notification(ctx.scope, notification.id)
      assert jobs_for(send.id) == []
    end
  end

  describe "API-13 API-16 repeated requests" do
    test "API-13: the same key and body replay the stored response and write nothing", ctx do
      notification = TenantFixture.notification(ctx.recipient)

      request =
        TenantFixture.accept_request([notification], data_key: ctx.keys.data, body: "same")

      assert {:ok, %{response: {202, _, body}}} = Relay.Ingest.accept(ctx.scope, request)

      again = %{request | notifications: [TenantFixture.notification(ctx.recipient)]}
      assert {:ok, %{replayed: replay}} = Relay.Ingest.accept(ctx.scope, again)
      assert replay.status == 202
      assert replay.body_ct == "sealed:" <> body
      assert {:ok, nil} = Relay.Delivery.notification(ctx.scope, hd(again.notifications).id)
    end

    test "API-13: the same key with another body is refused", ctx do
      key = "key-" <> TenantFixture.random()

      {:ok, _} =
        Relay.Ingest.accept(
          ctx.scope,
          TenantFixture.accept_request([TenantFixture.notification(ctx.recipient)],
            key: key,
            body: "one",
            data_key: ctx.keys.data
          )
        )

      assert {:error, %Relay.Error{code: :idempotency_conflict}} =
               Relay.Ingest.accept(
                 ctx.scope,
                 TenantFixture.accept_request([TenantFixture.notification(ctx.recipient)],
                   key: key,
                   body: "two",
                   data_key: ctx.keys.data
                 )
               )
    end

    test "API-16: a repeated dedup key returns the first notification and queues nothing", ctx do
      first = TenantFixture.notification(ctx.recipient, dedup_key: "order-1")

      {:ok, _} =
        Relay.Ingest.accept(
          ctx.scope,
          TenantFixture.accept_request([first], data_key: ctx.keys.data)
        )

      repeat = TenantFixture.notification(ctx.recipient, dedup_key: "order-1")

      assert {:ok, %{notifications: [%{id: id, result: :duplicate, deliveries: []}]}} =
               Relay.Ingest.accept(
                 ctx.scope,
                 TenantFixture.accept_request([repeat], data_key: ctx.keys.data)
               )

      assert id == first.id
      assert jobs_for(hd(repeat.deliveries).id) == []
    end
  end

  describe "TN-5 API-21 recipients and sub-tenants" do
    test "TN-5: an unknown sub-tenant opens the notification without it and skips its deliveries",
         ctx do
      send = TenantFixture.delivery()

      notification =
        TenantFixture.notification(ctx.recipient,
          subtenant_id: Relay.Id.generate(),
          deliveries: [send]
        )

      assert {:ok,
              %{notifications: [%{result: :scope_mismatch, deliveries: [%{decision: :skip}]}]}} =
               Relay.Ingest.accept(
                 ctx.scope,
                 TenantFixture.accept_request([notification], data_key: ctx.keys.data)
               )

      assert {:ok, %{"decision" => "skip", "decision_reason" => "scope_mismatch"}} =
               Relay.Delivery.delivery(ctx.scope, send.id)

      assert jobs_for(send.id) == []
    end

    test "API-21: an unknown recipient is reported and opens nothing", ctx do
      notification = TenantFixture.notification(Relay.Id.generate())

      assert {:ok, %{notifications: [%{id: nil, result: :recipient_not_found}]}} =
               Relay.Ingest.accept(
                 ctx.scope,
                 TenantFixture.accept_request([notification], data_key: ctx.keys.data)
               )
    end
  end
end
