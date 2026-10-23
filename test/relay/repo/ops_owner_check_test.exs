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

  alias Relay.Platform.Store

  @ops_functions """
  SELECT count(*) FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'relay_ops'
  """

  defp admin_query do
    conn = start_supervised!({Postgrex, RelayDev.Database.connection(:admin)}, id: make_ref())

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
end
