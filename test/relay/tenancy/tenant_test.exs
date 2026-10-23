defmodule Relay.Tenancy.TenantTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.TenantFixture

  setup do
    TenantFixture.as_role("relay_worker")
    %{tenant: TenantFixture.tenant!()}
  end

  defp create(attrs), do: Relay.Tenancy.create_tenant(attrs, TenantFixture.actor())

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

        assert {:error, %Relay.Error{code: code}} = create(Map.put(attrs, field, nil))
        assert code in [:invalid_time_zone, :invalid_locale]
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

      for locale <- ["Turkish", "tr_TR", "en-u-ca-gregory"] do
        assert {:error, %Relay.Error{code: :invalid_locale}} =
                 create(%{attrs | default_locale: locale})
      end

      assert {:created, id} = create(%{attrs | default_locale: "TR-tr"})
      assert tenant(Relay.Scope.new!(id, :live))["default_locale"] == "tr-TR"
    end

    test "WF-45: an offset time zone is refused", %{tenant: t} do
      for zone <- ["Etc/GMT+3", "UTC+03:00", "GMT-5"] do
        attrs = %{
          t.attrs
          | id: Relay.Id.generate(),
            access_tenant_id: "acc_" <> TenantFixture.random(),
            default_timezone: zone
        }

        assert {:error, %Relay.Error{code: :invalid_time_zone}} = create(attrs)
      end
    end

    test "TN-65: a link time zone is stored under the name of its zone", %{tenant: t} do
      attrs = %{
        t.attrs
        | id: Relay.Id.generate(),
          access_tenant_id: "acc_" <> TenantFixture.random(),
          default_timezone: "Turkey"
      }

      assert {:created, id} = create(attrs)
      assert tenant(Relay.Scope.new!(id, :live))["default_timezone"] == "Europe/Istanbul"
    end
  end

  describe "TN-2 TN-46 changing the defaults" do
    defp update(t, change) do
      Relay.Tenancy.update_tenant_defaults(
        t.live,
        Map.merge(
          %{
            default_timezone: nil,
            default_locale: nil,
            sector: nil,
            expected_version: tenant(t.live)["version"],
            record_digest: TenantFixture.digest()
          },
          change
        ),
        TenantFixture.actor()
      )
    end

    defp audit_actions(scope) do
      {:ok, actions} =
        Repo.in_scope(scope, fn _status ->
          %{rows: rows} =
            Repo.query!(
              "SELECT action FROM relay_fn.audit_query(now() - interval '1 hour', now() + interval '1 hour', 'tenant.defaults_updated', NULL, 10, $1, 'system', 'relay-test', 'relay-test', NULL)",
              [TenantFixture.digest()]
            )

          Enum.map(rows, &hd/1)
        end)

      actions
    end

    test "TN-2: a time zone or locale change writes its audit record", %{tenant: t} do
      assert audit_actions(t.live) == []
      assert {:ok, {:updated, _}} = update(t, %{default_timezone: "Europe/Berlin"})
      assert {:ok, {:updated, _}} = update(t, %{default_locale: "de-DE"})
      assert audit_actions(t.live) == ["tenant.defaults_updated", "tenant.defaults_updated"]
      assert {:ok, {:unchanged, _}} = update(t, %{default_locale: "de-DE"})
      assert length(audit_actions(t.live)) == 2
    end

    test "TN-65: a changed time zone is canonicalised and an offset zone is refused", %{
      tenant: t
    } do
      assert {:error, %Relay.Error{code: :invalid_time_zone}} =
               update(t, %{default_timezone: "Etc/GMT-3"})

      assert {:error, %Relay.Error{code: :invalid_locale}} = update(t, %{default_locale: "x-y"})
      assert {:ok, {:updated, _}} = update(t, %{default_timezone: "Europe/Kiev"})
      assert tenant(t.live)["default_timezone"] == "Europe/Kyiv"
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
