defmodule Relay.Repo.OpsOwnerCheckTest do
  use ExUnit.Case, async: true

  alias Relay.Platform.Store

  defp rows(rows), do: fn _sql, ["relay_maint"] -> {:ok, rows} end

  describe "OP-69 relay_ops ownership check" do
    test "OP-69: no relay_ops function with another owner passes" do
      assert Store.ops_owner_check(rows([])) == :ok
    end

    test "OP-69: a relay_ops function with another owner is refused and named" do
      assert {:error, %Relay.Error{code: :wrong_function_owner, details: %{functions: functions}}} =
               Store.ops_owner_check(rows([["relay_ops.orphan_check()", "relay_migrator"]]))

      assert functions == ["relay_ops.orphan_check() owned by relay_migrator"]
    end

    test "OP-69: a check that cannot run is refused" do
      assert {:error, %Relay.Error{code: :ops_owner_check_failed}} =
               Store.ops_owner_check(fn _sql, _params -> {:error, "connection refused"} end)
    end

    test "OP-69: the ownership check runs next to the role check among the first platform children" do
      assert [%{id: :relay_role_check}, %{id: :relay_ops_owner_check} | _] =
               Relay.Platform.children()
    end
  end
end

defmodule Relay.Repo.OpsOwnerCheckIntegrationTest do
  use Relay.DataCase, async: false

  import ExUnit.CaptureLog

  alias Relay.Platform.Store

  @ops_functions """
  SELECT count(*) FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'relay_ops'
  """

  @execute_grantees """
  SELECT ARRAY(
    SELECT pg_catalog.pg_get_userbyid(a.grantee)::text
    FROM pg_catalog.pg_proc p, pg_catalog.aclexplode(p.proacl) a
    WHERE p.oid = $1::text::regprocedure AND a.privilege_type = 'EXECUTE'
      AND a.grantee <> p.proowner
    ORDER BY 1)
  """

  defp admin_query, do: login_query(:admin)

  defp bootstrap, do: Relay.Release.bootstrap(RelayDev.Database.connection(:admin))

  defp restore(signature, definition) do
    {:ok, conn} = Postgrex.start_link(RelayDev.Database.connection(:admin))

    try do
      %{rows: [[present?]]} =
        Postgrex.query!(conn, "SELECT pg_catalog.to_regprocedure($1) IS NOT NULL", [signature])

      unless present?, do: Postgrex.query!(conn, definition, [])
    after
      GenServer.stop(conn)
    end

    :ok = bootstrap()
  end

  defp login_query(login) do
    conn = start_supervised!({Postgrex, RelayDev.Database.connection(login)}, id: make_ref())

    fn sql, params ->
      case Postgrex.query(conn, sql, params) do
        {:ok, %{rows: rows}} -> {:ok, rows}
        {:error, error} -> {:error, Exception.message(error)}
      end
    end
  end

  describe "OP-69 post-migration bootstrap" do
    test "OP-69: after the bootstrap every relay_ops function is owned by relay_maint" do
      query = admin_query()
      assert {:ok, [[count]]} = query.(@ops_functions, [])
      assert count > 0
      assert Store.ops_owner_check(query) == :ok
      assert Store.start_ops_owner_check() == :ignore
    end

    test "OP-69: a function handed to another owner stops the node until the bootstrap reruns" do
      query = admin_query()

      on_exit(fn -> Relay.Release.bootstrap(RelayDev.Database.connection(:admin)) end)

      assert {:ok, _} =
               query.("ALTER FUNCTION relay_ops.orphan_check() OWNER TO relay_migrator", [])

      assert {:error, %Relay.Error{code: :wrong_function_owner, details: details}} =
               Store.ops_owner_check(query)

      assert details.functions == ["relay_ops.orphan_check() owned by relay_migrator"]

      assert Relay.Release.bootstrap(RelayDev.Database.connection(:admin)) == :ok
      assert Store.ops_owner_check(query) == :ok
    end
  end

  describe "OP-72 (2) relay_ops function recreated by a migration" do
    test "OP-72 (2): a recreated function is owned by relay_migrator until the ownership step restores the owner and the contract grants" do
      admin = admin_query()
      migrator = login_query("relay_migrator")
      signature = "relay_ops.orphan_check()"
      save = "relay_ops.singleton_save(text, bigint, jsonb)"

      assert {:ok, [[definition]]} =
               admin.("SELECT pg_catalog.pg_get_functiondef($1::text::regprocedure)", [signature])

      on_exit(fn -> restore(signature, definition) end)

      assert {:ok, _} = admin.("DROP FUNCTION #{signature}", [])
      assert {:ok, _} = migrator.(definition, [])
      assert {:ok, _} = migrator.("GRANT EXECUTE ON FUNCTION #{signature} TO relay_worker", [])
      assert {:ok, _} = admin.("REVOKE EXECUTE ON FUNCTION #{save} FROM relay_worker", [])

      assert {:error, %Relay.Error{code: :wrong_function_owner, details: details}} =
               Store.ops_owner_check(admin)

      assert details.functions == ["#{signature} owned by relay_migrator"]

      {result, _log} = with_log(&Store.start_ops_owner_check/0)
      assert {:error, %Relay.Error{code: :wrong_function_owner}} = result

      assert bootstrap() == :ok
      assert bootstrap() == :ok

      assert Store.ops_owner_check(admin) == :ok
      assert Store.start_ops_owner_check() == :ignore
      assert {:ok, [[[]]]} = admin.(@execute_grantees, [signature])
      assert {:ok, [[["relay_worker"]]]} = admin.(@execute_grantees, [save])

      assert {:ok, [[false]]} =
               admin.(
                 "SELECT pg_catalog.pg_has_role('relay_migrator', 'relay_maint', 'MEMBER')",
                 []
               )
    end
  end
end
