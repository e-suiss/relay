defmodule Relay.Tenancy.RlsTest do
  use Relay.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Repo
  alias Relay.ScopeError
  alias RelayTest.TenantFixture

  defp in_savepoint(sql, params \\ []) do
    Repo.transaction(fn ->
      case Repo.query(sql, params) do
        {:ok, result} -> result
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  describe "TN-13 context-less queries fail" do
    setup do
      TenantFixture.as_role("relay_worker")
      :ok
    end

    test "TN-13: a query on a tenant table without any context is an error, not an empty result" do
      assert {:error, %Postgrex.Error{}} = in_savepoint("SELECT count(*) FROM relay.tenants")
    end

    test "TN-13: a tenant without an environment is still no context" do
      tenant = TenantFixture.tenant!()
      TenantFixture.subtenant!(tenant.live)

      assert {:error, %Postgrex.Error{}} =
               Repo.transaction(fn ->
                 Repo.query!("SELECT set_config('relay.tenant_id', $1, true)", [
                   Ecto.UUID.load!(tenant.id)
                 ])

                 Repo.query!("SELECT set_config('relay.environment', '', true)", [])

                 case Repo.query("SELECT count(*) FROM relay.subtenants", []) do
                   {:ok, result} -> result
                   {:error, error} -> Repo.rollback(error)
                 end
               end)
    end

    test "TN-13: the data layer refuses context-less tenant SQL before it reaches the database" do
      assert_raise ScopeError, fn -> Repo.scoped_query!("SELECT 1", []) end
    end

    test "TN-15: a tenant the context cannot see is not found" do
      assert {:error, %Relay.Error{code: :not_found}} =
               Repo.in_scope(Relay.Scope.new!(Relay.Id.generate(), :live), fn _ -> :never end)
    end
  end

  describe "TN-13 (5) the context is never inherited" do
    setup do
      TenantFixture.as_role("relay_worker")
      %{tenant: TenantFixture.tenant!()}
    end

    test "TN-13: the context is the first statement; a scope inside another transaction raises",
         %{
           tenant: tenant
         } do
      assert_raise ScopeError, ~r/first statement/, fn ->
        Repo.transaction(fn -> Repo.in_scope(tenant.live, fn _ -> :ok end) end)
      end
    end

    test "TN-13: a nested scope raises", %{tenant: tenant} do
      assert_raise ScopeError, ~r/already established/, fn ->
        Repo.in_scope(tenant.live, fn _ -> Repo.in_scope(tenant.test, fn _ -> :ok end) end)
      end
    end

    test "TN-13: a process started inside a scope has no scope", %{tenant: tenant} do
      parent = self()

      {:ok, :done} =
        Repo.in_scope(tenant.live, fn :active ->
          assert %Relay.Scope{} = Repo.current_scope()

          task =
            Task.async(fn ->
              Sandbox.allow(Repo, parent, self())
              send(parent, {:child_scope, Repo.current_scope()})

              send(
                parent,
                {:child_query, fn -> Repo.scoped_query!("SELECT 1", []) end |> catch_scope()}
              )
            end)

          Task.await(task)
          :done
        end)

      assert_received {:child_scope, nil}
      assert_received {:child_query, :refused}
      assert Repo.current_scope() == nil
    end

    test "TN-13: the scope ends with its transaction", %{tenant: tenant} do
      assert {:ok, :active} = Repo.in_scope(tenant.live, fn status -> status end)
      assert Repo.current_scope() == nil
      assert_raise ScopeError, fn -> Repo.scoped_query!("SELECT 1", []) end
    end

    test "TN-13: the scope is cleared even when the work raises", %{tenant: tenant} do
      assert_raise RuntimeError, fn -> Repo.in_scope(tenant.live, fn _ -> raise "boom" end) end
      assert Repo.current_scope() == nil
    end
  end

  describe "TN-13 the context is transaction-local" do
    test "TN-13: after commit the same connection carries no context" do
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, :ok} =
          Repo.transaction(fn ->
            Repo.query!("SELECT set_config('relay.tenant_id', $1, true)", [Ecto.UUID.generate()])
            Repo.query!("SELECT set_config('relay.environment', 'live', true)", [])
            :ok
          end)

        assert {:error, %Postgrex.Error{}} =
                 Repo.transaction(fn ->
                   TenantFixture.as_role("relay_worker")

                   case Repo.query("SELECT count(*) FROM relay.tenants", []) do
                     {:ok, result} -> result
                     {:error, error} -> Repo.rollback(error)
                   end
                 end)

        %{rows: [[tenant]]} = Repo.query!("SELECT current_setting('relay.tenant_id')", [])
        assert tenant == ""
      end)
    end
  end

  describe "TN-13 the environment is a second context setting" do
    setup do
      TenantFixture.as_role("relay_worker")
      tenant = TenantFixture.tenant!()
      TenantFixture.subtenant!(tenant.live)
      %{tenant: tenant}
    end

    test "TN-13: the live context does not see the test environment of the same tenant", %{
      tenant: tenant
    } do
      count = fn scope ->
        {:ok, count} =
          Repo.in_scope(scope, fn _ ->
            %{rows: [[count]]} = Repo.scoped_query!("SELECT count(*) FROM relay.subtenants", [])
            count
          end)

        count
      end

      assert count.(tenant.live) == 1
      assert count.(tenant.test) == 0
    end
  end

  defp catch_scope(fun) do
    fun.()
    :ran
  rescue
    ScopeError -> :refused
  end
end
