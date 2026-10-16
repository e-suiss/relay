defmodule Relay.Tenancy.ScopeAuditTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias Relay.ScopeError
  alias RelayTest.TenantFixture

  describe "TN-16 (3) every returned row is checked against the context" do
    test "TN-16: rows of another tenant are caught even when RLS does not apply to the role" do
      %{rows: [[super?]]} =
        Repo.query!("SELECT rolsuper FROM pg_roles WHERE rolname = current_user", [])

      if super? do
        a = TenantFixture.tenant!()
        b = TenantFixture.tenant!()
        TenantFixture.subtenant!(a.live)
        TenantFixture.subtenant!(b.live)

        assert_raise ScopeError, ~r/outside the established scope/, fn ->
          Repo.in_scope(a.live, fn _ ->
            Repo.scoped_query!("SELECT tenant_id, environment, id FROM relay.subtenants", [])
          end)
        end
      end
    end

    test "TN-16: rows of the context pass the check under the application role" do
      TenantFixture.as_role("relay_worker")
      a = TenantFixture.tenant!()
      TenantFixture.subtenant!(a.live)

      assert {:ok, %{num_rows: 1}} =
               Repo.in_scope(a.live, fn _ ->
                 Repo.scoped_query!("SELECT tenant_id, environment, id FROM relay.subtenants", [])
               end)
    end
  end
end
