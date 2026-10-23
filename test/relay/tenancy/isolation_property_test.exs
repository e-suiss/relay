defmodule Relay.Tenancy.IsolationPropertyTest do
  use Relay.DataCase, async: false
  use ExUnitProperties

  alias Relay.Repo
  alias RelayTest.TenantFixture

  @shared ~w(dataset_versions dataset_active)

  defp populate(scope) do
    keys = TenantFixture.keys!(scope)
    recipient = TenantFixture.recipient!(scope, keys)
    subtenant = TenantFixture.subtenant!(scope)

    {:ok, {:created, _}} =
      Relay.Tenancy.put_setting(
        scope,
        %{
          subtenant_id: subtenant,
          key: "default_locale",
          value: "en-GB",
          record_digest: TenantFixture.digest()
        },
        TenantFixture.actor()
      )

    outbox = [
      %{
        id: Relay.Id.generate(),
        event_type: "notification.accepted",
        stream_key: "events:" <> TenantFixture.random(),
        payload: %{"n" => 1}
      }
    ]

    {:ok, _} =
      Relay.Ingest.accept(
        scope,
        TenantFixture.accept_request([TenantFixture.notification(recipient)],
          outbox: outbox,
          data_key: keys.data
        )
      )

    :ok
  end

  defp tenant_tables do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
        WHERE n.nspname = 'relay' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
          AND has_table_privilege(current_user, c.oid, 'SELECT')
        ORDER BY c.relname
        """,
        []
      )

    List.flatten(rows)
  end

  setup do
    TenantFixture.as_role("relay_worker")
    a = TenantFixture.tenant!()
    b = TenantFixture.tenant!()
    for tenant <- [a, b], scope <- [tenant.live, tenant.test], do: populate(scope)
    %{scopes: [a.live, a.test, b.live, b.test], tables: tenant_tables()}
  end

  describe "TN-16 (2) a tenant's queries never return another tenant's rows" do
    test "TN-16: the populated tenant tables are readable by the application role", %{
      tables: tables
    } do
      for table <- ~w(notifications deliveries subtenants settings recipients outbox_events),
          do: assert(table in tables)
    end

    property "TN-16: every row a scope reads carries its own tenant and environment", %{
      scopes: scopes,
      tables: tables
    } do
      check all scope <- member_of(scopes), table <- member_of(tables -- @shared), max_runs: 60 do
        {:ok, rows} =
          Repo.in_scope(scope, fn _ ->
            %{rows: rows} =
              Repo.scoped_query!("SELECT tenant_id, environment FROM relay.#{table}", [])

            rows
          end)

        env = Relay.Environment.dump(scope.environment)
        assert Enum.all?(rows, &(&1 == [scope.tenant_id, env]))
      end
    end

    property "TN-16: installation-wide data sets add only the installation tenant's live rows", %{
      scopes: scopes
    } do
      check all scope <- member_of(scopes), table <- member_of(@shared), max_runs: 10 do
        {:ok, {installation, rows}} =
          Repo.in_scope(scope, fn _ ->
            %{rows: [[installation]]} =
              Repo.query!("SELECT relay_private.installation_tenant_id()", [])

            %{rows: rows} =
              Repo.scoped_query!("SELECT tenant_id, environment FROM relay.#{table}", [],
                shared: :installation
              )

            {installation, rows}
          end)

        env = Relay.Environment.dump(scope.environment)
        assert Enum.all?(rows, &(&1 in [[scope.tenant_id, env], [installation, "live"]]))
      end
    end

    property "TN-16: the root tenant table shows a scope only its own tenant", %{scopes: scopes} do
      check all scope <- member_of(scopes), max_runs: 10 do
        {:ok, rows} =
          Repo.in_scope(scope, fn _ ->
            Repo.scoped_query!("SELECT id FROM relay.tenants", []).rows
          end)

        assert rows == [[scope.tenant_id]]
      end
    end

    property "TN-15: another scope's notification is not found", %{scopes: scopes} do
      check all [mine, theirs] <- list_of(member_of(scopes), length: 2),
                mine != theirs,
                max_runs: 20 do
        {:ok, ids} =
          Repo.in_scope(theirs, fn _ ->
            Repo.scoped_query!("SELECT id FROM relay.notifications", []).rows
          end)

        for [id] <- ids, do: assert({:ok, nil} == Relay.Delivery.notification(mine, id))
      end
    end
  end
end
