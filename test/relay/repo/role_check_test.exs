defmodule Relay.Repo.RoleCheckTest do
  use ExUnit.Case, async: true

  alias Relay.Platform.Store

  @passing %{
    roles: [{"relay_worker", false, false}, {"relay_app", false, false}],
    owned: [],
    tables: [
      {"relay", "notifications", ["SELECT"]},
      {"relay_queue", "oban_jobs", ["SELECT", "INSERT", "UPDATE"]}
    ],
    schemas: [{"relay", true}, {"relay_queue", true}],
    current_user: "relay_worker",
    session_user: "relay_worker",
    server_version_num: 180_006,
    server_version: "18.6 (Debian 18.6-1.pgdg13+1)",
    row_security: "on",
    statement_timeout_ms: 30_000,
    context_settings: []
  }

  defp violations(facts, profile \\ {:app, [:worker]}) do
    case Store.evaluate(facts, profile) do
      :ok -> []
      {:error, %Relay.Error{code: :wrong_database_role, details: %{violations: found}}} -> found
    end
  end

  describe "TN-14 startup role check" do
    test "TN-14: an unprivileged worker login passes" do
      assert violations(@passing) == []
    end

    test "TN-14: a superuser or a role that bypasses row level security is refused, also through membership" do
      assert :privileged_role in violations(%{@passing | roles: [{"relay_worker", true, false}]})

      assert :privileged_role in violations(%{
               @passing
               | roles: [{"relay_worker", false, false}, {"relay_maint", false, true}]
             })
    end

    test "TN-14: a login that owns any object is refused" do
      assert :owns_objects in violations(%{@passing | owned: ["relation relay.notifications"]})
    end

    test "TN-14: DELETE or TRUNCATE on any table, the queue tables included, is refused" do
      for privilege <- ["DELETE", "TRUNCATE"] do
        tables = [{"relay_queue", "oban_jobs", ["SELECT", privilege]}]
        assert :delete_or_truncate in violations(%{@passing | tables: tables})
      end
    end

    test "TN-14: INSERT or UPDATE on a record table is refused" do
      for privilege <- ["INSERT", "UPDATE"] do
        tables = [{"relay", "notifications", ["SELECT", privilege]}]
        assert :writes_record_tables in violations(%{@passing | tables: tables})
      end
    end

    test "TN-14: a switched role or a login that does not match the node roles is refused" do
      assert :role_switched in violations(%{@passing | current_user: "relay_api"})
      assert :wrong_login_role in violations(@passing, {:app, [:api]})

      assert :wrong_login_role in violations(%{
               @passing
               | session_user: "relay_api",
                 current_user: "relay_api"
             })
    end

    test "TN-14: api and socket nodes use relay_api and worker nodes use relay_worker" do
      assert Store.expected_logins([:api]) == ["relay_api"]
      assert Store.expected_logins([:socket]) == ["relay_api"]
      assert Store.expected_logins([:worker]) == ["relay_worker"]
      assert Store.expected_logins([:api, :worker, :socket]) == ["relay_api", "relay_worker"]
    end

    test "TN-14: row security off or a statement timeout other than the role's is refused" do
      assert :row_security_off in violations(%{@passing | row_security: "off"})
      assert :statement_timeout in violations(%{@passing | statement_timeout_ms: 0})
    end

    test "TN-13: a tenant or environment context preset on the role, database or session is refused" do
      assert :tenant_context_preset in violations(%{
               @passing
               | context_settings: ["relay.tenant_id"]
             })

      assert :tenant_context_preset in violations(%{
               @passing
               | context_settings: ["relay.environment"]
             })
    end

    test "TN-14: the queue login may delete only in the queue schema and holds nothing outside it" do
      queue = %{
        @passing
        | roles: [{"relay_queue", false, false}],
          current_user: "relay_queue",
          session_user: "relay_queue",
          statement_timeout_ms: 60_000,
          tables: [
            {"relay_queue", "oban_jobs", ["SELECT", "DELETE"]},
            {"relay", "notifications", []}
          ],
          schemas: [{"relay", false}, {"relay_queue", true}]
      }

      assert violations(queue, :queue) == []

      assert :outside_queue_schema in violations(
               %{queue | tables: [{"relay", "notifications", ["SELECT"]}]},
               :queue
             )

      assert :outside_queue_schema in violations(%{queue | schemas: [{"relay", true}]}, :queue)

      assert :delete_or_truncate in violations(
               %{queue | tables: [{"relay_queue", "oban_jobs", ["TRUNCATE"]}]},
               :queue
             )
    end
  end

  describe "T-8 PostgreSQL version" do
    test "T-8: PostgreSQL older than 18 stops the node" do
      assert :unsupported_postgres in violations(%{
               @passing
               | server_version_num: 170_005,
                 server_version: "17.5"
             })
    end

    test "T-8: a beta, release candidate or development build stops the node" do
      for version <- ["18beta3", "18rc1", "19devel"] do
        assert :unsupported_postgres in violations(%{@passing | server_version: version})
      end
    end
  end
end

defmodule Relay.Repo.RoleCheckIntegrationTest do
  use Relay.DataCase, async: true

  alias Relay.Platform.Store

  defp check(login, profile) do
    conn = start_supervised!({Postgrex, login_options(login)}, id: make_ref())

    Store.role_check(
      fn sql, params ->
        case Postgrex.query(conn, sql, params) do
          {:ok, %{rows: rows}} -> {:ok, rows}
          {:error, error} -> {:error, error}
        end
      end,
      profile
    )
  end

  defp login_options(:admin), do: RelayDev.Database.connection(:admin)
  defp login_options(role), do: RelayDev.Database.connection(role)

  defp violations(login, profile) do
    case check(login, profile) do
      :ok -> []
      {:error, %Relay.Error{details: %{violations: found}}} -> found
    end
  end

  describe "TN-14 TN-16 real logins" do
    test "TN-16: the node's own login passes the check it runs at startup" do
      assert Store.role_check() == :ok
      assert Store.start_role_check() == :ignore
    end

    test "TN-14: the role check is the first platform child, so a failing check stops the node" do
      assert [%{id: :relay_role_check, start: {Store, :start_role_check, []}} | _] =
               Relay.Platform.children()
    end

    test "TN-14: relay_api passes for an api node and relay_worker for a worker node" do
      assert violations("relay_api", {:app, [:api, :socket]}) == []
      assert violations("relay_worker", {:app, [:worker]}) == []
    end

    test "TN-14: relay_api is refused on a worker-only node" do
      assert violations("relay_api", {:app, [:worker]}) == [:wrong_login_role]
    end

    test "TN-14: the superuser is refused" do
      found = violations(:admin, {:app, [:api]})
      assert :privileged_role in found
      assert :wrong_login_role in found
    end

    test "TN-14: the migrator is refused as the owner of the tables" do
      found = violations("relay_migrator", {:app, [:worker]})
      assert :owns_objects in found
      assert :writes_record_tables in found
      assert :delete_or_truncate in found
    end

    test "TN-14: the maintenance and archive logins are refused because they bypass row level security" do
      assert :privileged_role in violations("relay_maint", {:app, [:worker]})
      assert :privileged_role in violations("relay_archive", {:app, [:worker]})
    end

    test "TN-14: the queue login passes the queue check and fails the application check" do
      assert violations("relay_queue", :queue) == []

      found = violations("relay_queue", {:app, [:worker]})
      assert :delete_or_truncate in found
      assert :wrong_login_role in found
    end

    test "TN-14: an application login fails the queue check" do
      found = violations("relay_worker", :queue)
      assert :outside_queue_schema in found
      assert :wrong_login_role in found
    end

    test "TN-13: a tenant context set on the session is refused" do
      conn = start_supervised!({Postgrex, login_options("relay_worker")}, id: :preset)
      Postgrex.query!(conn, "SET relay.tenant_id = '00000000-0000-7000-8000-000000000000'", [])

      query = fn sql, params ->
        case Postgrex.query(conn, sql, params) do
          {:ok, %{rows: rows}} -> {:ok, rows}
          {:error, error} -> {:error, error}
        end
      end

      assert {:error, %Relay.Error{details: %{violations: [:tenant_context_preset]}}} =
               Store.role_check(query, {:app, [:worker]})
    end
  end
end
