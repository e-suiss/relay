defmodule Relay.Tenancy.ScopeAuditTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.TenantFixture

  describe "TN-16 (3) every returned row is checked against the context" do
    test "TN-16: rows read in a scope pass the scope check" do
      a = TenantFixture.tenant!()
      b = TenantFixture.tenant!()
      TenantFixture.subtenant!(a.live)
      TenantFixture.subtenant!(b.live)

      assert {:ok, %{num_rows: 1, rows: [[tenant_id, "live", _id]]}} =
               Repo.in_scope(a.live, fn _ ->
                 Repo.scoped_query!("SELECT tenant_id, environment, id FROM relay.subtenants", [])
               end)

      assert tenant_id == a.id
    end
  end
end
