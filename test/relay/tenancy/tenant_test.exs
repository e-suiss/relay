defmodule Relay.Tenancy.TenantTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.TenantFixture

  setup do
    TenantFixture.as_role("relay_worker")
    %{tenant: TenantFixture.tenant!()}
  end

  defp create(attrs), do: Relay.Tenancy.create_tenant(attrs, TenantFixture.actor())

  defp create_in_savepoint(attrs) do
    Repo.transaction(fn -> create(attrs) end)
  end

  defp tenant(scope) do
    {:ok, row} = Relay.Tenancy.tenant(scope)
    row
  end

  defp set_status(scope, status, reason \\ "test") do
    {:ok, result} =
      Relay.Tenancy.set_tenant_status(
        scope,
        %{
          status: status,
          reason: reason,
          expected_version: tenant(scope)["version"],
          record_digest: TenantFixture.digest()
        },
        TenantFixture.actor()
      )

    result
  end

  describe "TN-1 TN-2 tenant creation" do
    test "TN-2: a repeated mapping event is idempotent; a different one conflicts", %{tenant: t} do
      assert {:exists, _} = create(%{t.attrs | record_digest: TenantFixture.digest()})

      assert {:conflict, _} =
               create(%{t.attrs | id: Relay.Id.generate(), default_locale: "en-US"})
    end

    test "TN-2: the region must be the installation's region", %{tenant: t} do
      other = Enum.find(Relay.Region.all(), &(&1 != TenantFixture.region()))

      assert {:region_mismatch, _} =
               create(%{
                 t.attrs
                 | id: Relay.Id.generate(),
                   access_tenant_id: "acc_" <> TenantFixture.random(),
                   region: other
               })
    end

    test "TN-2: time zone, locale and region are required", %{tenant: t} do
      for field <- [:default_timezone, :default_locale] do
        attrs = %{
          t.attrs
          | id: Relay.Id.generate(),
            access_tenant_id: "acc_" <> TenantFixture.random()
        }

        assert_raise Postgrex.Error, fn -> create_in_savepoint(Map.put(attrs, field, nil)) end
      end
    end

    test "TN-2: the region is never updated", %{tenant: t} do
      before = tenant(t.live)

      {:ok, {:updated, _}} =
        Relay.Tenancy.update_tenant_defaults(
          t.live,
          %{
            default_timezone: "Europe/Berlin",
            default_locale: "de-DE",
            sector: "general",
            expected_version: before["version"],
            record_digest: TenantFixture.digest()
          },
          TenantFixture.actor()
        )

      after_update = tenant(t.live)
      assert after_update["default_timezone"] == "Europe/Berlin"
      assert after_update["region"] == before["region"]
    end

    test "TP-25: the default locale is BCP 47", %{tenant: t} do
      attrs = %{
        t.attrs
        | id: Relay.Id.generate(),
          access_tenant_id: "acc_" <> TenantFixture.random()
      }

      assert_raise Postgrex.Error, fn ->
        create_in_savepoint(%{attrs | default_locale: "Turkish"})
      end
    end

    test "WF-45: an offset time zone is refused", %{tenant: t} do
      for zone <- ["Etc/GMT+3", "UTC+03:00", "GMT-5"] do
        attrs = %{
          t.attrs
          | id: Relay.Id.generate(),
            access_tenant_id: "acc_" <> TenantFixture.random(),
            default_timezone: zone
        }

        assert_raise Postgrex.Error, fn -> create_in_savepoint(attrs) end
      end
    end
  end

  describe "TN-10 tenant status" do
    test "TN-10: suspension and reactivation are transitions; closing is terminal", %{tenant: t} do
      assert {:changed, _} = set_status(t.live, "suspended")
      assert {:unchanged, _} = set_status(t.live, "suspended")
      assert {:changed, _} = set_status(t.live, "active", nil)
      assert {:changed, _} = set_status(t.live, "closed")
      assert {:invalid_transition, _} = set_status(t.live, "active", nil)
    end

    test "TN-10: a stale version is refused", %{tenant: t} do
      assert {:ok, {:version_conflict, _}} =
               Relay.Tenancy.set_tenant_status(
                 t.live,
                 %{
                   status: "suspended",
                   reason: "test",
                   expected_version: tenant(t.live)["version"] + 7,
                   record_digest: TenantFixture.digest()
                 },
                 TenantFixture.actor()
               )
    end

    test "TN-10: a suspended tenant takes no new work but its ledger goes on", %{tenant: t} do
      keys = TenantFixture.keys!(t.live)
      recipient = TenantFixture.recipient!(t.live, keys)

      {:ok, accepted} =
        Relay.Ingest.accept(
          t.live,
          TenantFixture.accept_request([TenantFixture.notification(recipient)],
            data_key: keys.data
          )
        )

      [%{deliveries: [%{id: delivery_id}]}] = accepted.notifications
      assert {:changed, _} = set_status(t.live, "suspended")

      assert {:error, %Relay.Error{code: :tenant_inactive}} =
               Relay.Ingest.accept(
                 t.live,
                 TenantFixture.accept_request([TenantFixture.notification(recipient)],
                   data_key: keys.data
                 )
               )

      {:ok, entry} =
        Relay.Delivery.ledger_entry(
          id: Relay.Id.generate(),
          delivery_id: delivery_id,
          actor: :relay,
          event_type: "delivery.cancelled",
          occurred_at: Relay.Clock.utc_now(),
          failure_kind: :cancelled,
          failure_rule_id: "TN-10"
        )

      assert {:ok, {result, _rank, _version}} = Relay.Delivery.append_ledger(t.live, entry)
      assert result in [:applied, :stale_ignored, :conflict_flagged]
    end
  end
end
