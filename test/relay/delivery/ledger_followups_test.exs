defmodule Relay.Delivery.LedgerFollowupsTest do
  use Relay.DataCase, async: false

  alias Relay.Delivery.FailureActorBackfill
  alias Relay.Repo
  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture

  setup do
    DeliveryFixture.sendable!()
  end

  defp append(scope, id, attrs) do
    {:ok, entry} =
      Relay.Delivery.ledger_entry(
        Map.merge(
          %{
            id: Relay.Id.generate(),
            delivery_id: id,
            actor: :provider_webhook,
            provider: "fake",
            event_type: "provider.reported",
            occurred_at: Relay.Clock.utc_now()
          },
          Map.new(attrs)
        )
      )

    {:ok, {result, _rank, _version}} = Relay.Delivery.append_ledger(scope, entry)
    result
  end

  defp sql!(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp delivery(scope, id) do
    {:ok, delivery} = Relay.Delivery.delivery(scope, id)
    delivery
  end

  describe "DS-4 the failure source backfill" do
    test "OP-3: a finished pass stays idle" do
      state = %{"finished_at" => "2026-12-01T00:00:00Z", "scanned" => 3, "updated" => 1}

      assert {:ok, ^state, delay} =
               FailureActorBackfill.run(%{
                 name: "failure_actor_backfill",
                 node: "n",
                 fencing_token: 1,
                 state: state
               })

      assert delay >= 3_600_000
    end

    test "OP-3: the pass walks the scopes in order" do
      tenant = Relay.Id.generate()
      a = %{tenant_id: tenant, environment: "live"}
      b = %{tenant_id: tenant, environment: "test"}
      scopes = [a, b]

      assert FailureActorBackfill.current(scopes, nil) == a
      assert FailureActorBackfill.next(scopes, a) == b
      assert FailureActorBackfill.next(scopes, b) == nil
    end
  end

  describe "DS-20 DS-2 late events after retention" do
    test "DS-20, DS-2, DS-44: an event after retention is only written and counted", %{
      scope: scope,
      delivery_id: id,
      notification_id: notification_id,
      keys: keys
    } do
      {:ok, %{"recipient_id" => recipient}} = Relay.Delivery.notification(scope, notification_id)

      {:ok, %{wrapped_dek: wrapped}} =
        Relay.Tenancy.generate_subject_key(scope, keys.dek_wrap, recipient, :delivery_record)

      [[_result, key_id]] =
        sql!(
          scope,
          "SELECT result, subject_key_id FROM relay_fn.subject_key_create($1, $2, 'delivery_record', $3, $4)",
          [Relay.Id.generate(), recipient, wrapped, keys.dek_wrap]
        )

      [["retired"]] =
        sql!(
          scope,
          "SELECT relay_fn.subject_key_retire($1, $2, 'system', 'relay-test', 'relay-test', NULL)",
          [key_id, TenantFixture.digest()]
        )

      %{"projection_version" => version} = delivery(scope, id)
      assert append(scope, id, delivery_rank: :delivered) == :stale_ignored

      assert %{"delivery_rank" => 0, "late_event_count" => 1, "projection_version" => ^version} =
               delivery(scope, id)

      {:ok, ledger} = Relay.Delivery.ledger(scope, id)
      reported = Enum.find(ledger, &(&1["event_type"] == "provider.reported"))
      assert reported["detail"]["effect"]["retention_ended"] == true
      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end
  end
end
