defmodule Relay.ScopeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Ecto.Query, only: [from: 2]

  alias Relay.Repo
  alias Relay.Scope
  alias Relay.ScopeError
  alias Relay.Tenancy.Context

  @tenant <<1::128>>
  @other <<2::128>>

  describe "TN-13 the data access layer refuses context-less work" do
    test "TN-13: tenant-scoped SQL outside a scoped transaction raises before reaching the database" do
      assert_raise ScopeError, ~r/without a tenant context/, fn ->
        Repo.scoped_query("SELECT 1", [])
      end

      assert_raise ScopeError, fn -> Repo.scoped_query!("SELECT 1", []) end
      assert_raise ScopeError, fn -> Repo.call!("relay_fn.outbox_claim", [1]) end
    end

    test "TN-13: an Ecto query without a scope is refused" do
      assert_raise ScopeError, fn ->
        Repo.prepare_query(:all, from(n in "notifications", select: n.id), [])
      end
    end

    test "TN-13: the job queue and the migrator keep their own queries" do
      query = from(j in "oban_jobs", select: j.id)
      assert {^query, _} = Repo.prepare_query(:all, query, oban: true)
      assert {^query, _} = Repo.prepare_query(:all, query, schema_migration: true)
    end

    test "TN-13: a cross-tenant call needs a declared escape hatch" do
      assert_raise ScopeError, ~r/escape hatch/, fn ->
        Repo.unscoped_query(undeclared(), "SELECT 1", [])
      end

      assert_raise ScopeError, fn -> Repo.call_unscoped!(undeclared(), "relay_ops.x", []) end

      assert Repo.escapes() == [
               :tenant_bootstrap,
               :outbox_scope_discovery,
               :installation_lookup,
               :fair_dispatch,
               :load_shed,
               :dead_letter_scope_discovery,
               :kill_switch_snapshot,
               :kill_switch_scopes,
               :waitpoint_due_discovery
             ]
    end

    test "TN-13: no scope is visible outside a scoped transaction" do
      assert Repo.current_scope() == nil
    end

    test "TN-13: the scoped call reaches only relay_fn and the escape call only relay_ops" do
      assert_raise ArgumentError, fn -> Repo.call!("relay_ops.outbox_pending_scopes", [1]) end
      assert_raise ArgumentError, fn -> Repo.call!("relay_fn.x; DROP", []) end

      assert_raise ArgumentError, fn ->
        Repo.call_unscoped!(:tenant_bootstrap, "relay_fn.ctx_set", [])
      end
    end
  end

  describe "TN-16 (3) returned rows match the scope" do
    setup do
      %{scope: Scope.new!(@tenant, :live)}
    end

    test "TN-16: rows of the scope pass", %{scope: scope} do
      result = %Postgrex.Result{
        columns: ["tenant_id", "environment", "id"],
        rows: [[@tenant, "live", 1]]
      }

      assert Repo.check_rows!(scope, result) == result
    end

    test "TN-16: a row of another tenant raises", %{scope: scope} do
      result = %Postgrex.Result{columns: ["id", "tenant_id"], rows: [[1, @tenant], [2, @other]]}

      assert_raise ScopeError, ~r/outside the established scope/, fn ->
        Repo.check_rows!(scope, result)
      end
    end

    test "TN-16: a row of the other environment raises", %{scope: scope} do
      result = %Postgrex.Result{columns: ["environment"], rows: [["test"]]}
      assert_raise ScopeError, fn -> Repo.check_rows!(scope, result) end
    end

    test "TN-16: a shared scope admits only its own rows besides the context", %{scope: scope} do
      shared = [Scope.new!(@other, :live)]
      result = %Postgrex.Result{columns: ["tenant_id", "environment"], rows: [[@other, "live"]]}
      assert Repo.check_rows!(scope, result, shared) == result

      other_env = %Postgrex.Result{result | rows: [[@other, "test"]]}
      assert_raise ScopeError, fn -> Repo.check_rows!(scope, other_env, shared) end
    end

    test "TN-16: results without scope columns are not inspected", %{scope: scope} do
      result = %Postgrex.Result{columns: ["result"], rows: [["created"]]}
      assert Repo.check_rows!(scope, result) == result
      assert Repo.check_rows!(scope, %Postgrex.Result{columns: nil, rows: nil}).rows == nil
    end
  end

  describe "TN-13 (5) the scope crosses boundaries only explicitly" do
    property "TN-13: job arguments carry the scope as identifiers and rebuild it" do
      check all tenant <- binary(length: 16), environment <- member_of([:live, :test]) do
        scope = Scope.new!(tenant, environment)
        args = Scope.to_job_args(scope)

        assert Map.keys(args) == ["environment", "tenant_id"]
        assert Enum.all?(Map.values(args), &is_binary/1)
        assert Scope.from_job_args(Jason.decode!(Jason.encode!(args))) == {:ok, scope}
      end
    end

    test "TN-13: malformed scopes and job arguments are refused" do
      assert {:error, %Relay.Error{code: :invalid_scope}} = Scope.new("tenant", :live)
      assert {:error, %Relay.Error{code: :invalid_environment}} = Scope.new(@tenant, :staging)
      assert {:error, _} = Scope.from_job_args(%{"tenant_id" => "x", "environment" => "live"})
      assert {:error, _} = Scope.from_job_args(%{"delivery_id" => "x"})
    end

    test "TN-13: a scope inspects without its raw bytes" do
      assert inspect(Scope.new!(@tenant, :test)) ==
               "#Relay.Scope<00000000-0000-0000-0000-000000000001/test>"
    end

    test "T-15: tenancy job arguments add identifiers and nothing else" do
      args = Context.job_args(Scope.new!(@tenant, :live), %{"delivery_id" => "d"})
      assert args["delivery_id"] == "d"
      assert {:ok, %Scope{environment: :live}} = Context.from_job_args(args)
    end

    test "TN-10: only an active tenant takes new work" do
      assert Relay.Tenancy.require_active(:active) == :ok

      for status <- [:suspended, :closed] do
        assert {:error, %Relay.Error{code: :tenant_inactive}} =
                 Relay.Tenancy.require_active(status)
      end
    end
  end

  describe "C-4 result codes" do
    test "C-4: a result code decodes only from its closed set" do
      assert Repo.code!("created", [:created, :exists]) == :created
      assert_raise ArgumentError, fn -> Repo.code!("gone", [:created, :exists]) end
    end
  end

  describe "TN-48 actors" do
    test "TN-48: an actor names who acts and on whose behalf" do
      assert {:ok, actor} = Relay.Actor.new(:operator, "acc_user_1", "acc_tenant_1", "rec_9")
      assert Relay.Actor.params(actor) == ["operator", "acc_user_1", "acc_tenant_1", "rec_9"]
      assert {:error, _} = Relay.Actor.new(:robot, "a", "b")
      assert {:error, _} = Relay.Actor.new(:system, "", "b")
    end
  end

  defp undeclared, do: Process.get(:undeclared_escape, :anything)
end
