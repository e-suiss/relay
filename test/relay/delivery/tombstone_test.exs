defmodule Relay.Delivery.TombstoneTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "cart-reminder")
    %{scope: tenant.live, token: token}
  end

  defp recipient,
    do: %{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}

  defp accept!(token, overrides) do
    body =
      Map.merge(
        %{"workflow" => "cart-reminder", "to" => [recipient()], "data" => %{"order" => "A-1"}},
        overrides
      )

    F.body(F.request(:post, "/v1/events", token, body), 202)
  end

  defp delivery_ids(token, notification) do
    path = "/v1/notifications/#{notification}/deliveries"

    for %{"id" => id} <- F.body(F.request(:get, path, token), 200)["data"] do
      {:ok, delivery_id} = Relay.ExternalId.decode(id, ["dlv"])
      {id, delivery_id}
    end
  end

  defp run!(delivery) do
    [job] = F.delivery_jobs(delivery)
    Relay.Delivery.Send.perform(%Oban.Job{args: Map.delete(job, "queue")})
  end

  defp state(scope, delivery_id) do
    {:ok, [[kind, rule]]} =
      Repo.in_scope(scope, fn _status ->
        Repo.scoped_query!(
          "SELECT failure_kind, failure_rule_id FROM relay.deliveries WHERE id = $1",
          [delivery_id]
        ).rows
      end)

    {kind, rule}
  end

  defp notification_state(scope, notification) do
    {:ok, id} = Relay.ExternalId.decode(notification, ["ntf"])

    {:ok, [[state, rule]]} =
      Repo.in_scope(scope, fn _status ->
        Repo.scoped_query!(
          "SELECT state, close_rule_id FROM relay.notifications WHERE id = $1",
          [id]
        ).rows
      end)

    {state, rule}
  end

  defp cancel_by_key!(scope, key, limit) do
    cancellation = %{
      id: Relay.Id.generate(),
      key: key,
      recipient_ids: nil,
      channels: nil,
      reason: "test",
      limit: limit
    }

    {:ok, row} =
      Relay.Ingest.in_event_scope(scope, fn _status ->
        Relay.Ingest.cancel_by_key(cancellation, TenantFixture.actor())
      end)

    {cancellation.id, row}
  end

  describe "API-58 INV-6 tombstone at run start" do
    test "API-58, INV-6: a run that starts after a key tombstone becomes cancelled", ctx do
      send_at = Relay.Clock.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

      body =
        accept!(ctx.token, %{
          "to" => [recipient(), recipient()],
          "cancellation_key" => "cart-9",
          "send_at" => send_at
        })

      [first, second] = Enum.map(body["notifications"], & &1["notification_id"])

      {cancellation_id, row} = cancel_by_key!(ctx.scope, "cart-9", 1)
      assert row["cancelled"] == 1
      assert row["has_more"] == true

      rule = "cancelled:" <> Relay.Id.to_string(cancellation_id)
      [{_first_text, first_id}] = delivery_ids(ctx.token, first)
      assert state(ctx.scope, first_id) == {"cancelled", rule}

      [{second_text, second_id}] = delivery_ids(ctx.token, second)
      assert state(ctx.scope, second_id) == {nil, nil}

      assert run!(second_text) == :ok
      assert state(ctx.scope, second_id) == {"cancelled", rule}
      assert notification_state(ctx.scope, second) == {"cancelled", rule}
    end

    test "API-58: an event cancelled past its limit stops the rest at run start", ctx do
      body = accept!(ctx.token, %{"to" => [recipient(), recipient()]})
      {:ok, event_id} = Relay.ExternalId.decode(body["id"], ["evt"])

      {:ok, row} =
        Relay.Ingest.in_event_scope(ctx.scope, fn _status ->
          Relay.Ingest.cancel_event(Relay.Id.generate(), event_id, "x", 1, TenantFixture.actor())
        end)

      assert row["has_more"] == true
      [_first, second] = Enum.map(body["notifications"], & &1["notification_id"])
      [{second_text, second_id}] = delivery_ids(ctx.token, second)

      assert run!(second_text) == :ok
      assert {"cancelled", "cancelled:" <> _} = state(ctx.scope, second_id)
    end

    test "API-58: a run without a tombstone goes on to the gate", ctx do
      body = accept!(ctx.token, %{"cancellation_key" => "cart-10"})
      [%{"notification_id" => notification}] = body["notifications"]
      [{delivery, delivery_id}] = delivery_ids(ctx.token, notification)

      assert run!(delivery) == {:snooze, 300}
      assert state(ctx.scope, delivery_id) == {nil, nil}
    end

    test "API-58: a key tombstone does not cover an event accepted after it", ctx do
      {_cancellation_id, _row} = cancel_by_key!(ctx.scope, "cart-11", 10)
      body = accept!(ctx.token, %{"cancellation_key" => "cart-11"})
      [%{"notification_id" => notification}] = body["notifications"]
      [{delivery, delivery_id}] = delivery_ids(ctx.token, notification)

      assert run!(delivery) == {:snooze, 300}
      assert state(ctx.scope, delivery_id) == {nil, nil}
    end
  end
end
