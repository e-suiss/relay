defmodule Relay.Tenancy.SubtenantTest do
  use Relay.DataCase, async: false

  alias RelayTest.TenantFixture

  setup do
    TenantFixture.as_role("relay_worker")
    %{tenant: TenantFixture.tenant!()}
  end

  defp upsert(scope, id, name) do
    {:ok, result} =
      Relay.Tenancy.upsert_subtenant(
        scope,
        %{
          id: id,
          access_organization_id: "org_" <> Base.encode16(id, case: :lower),
          name: name,
          record_digest: TenantFixture.digest()
        },
        TenantFixture.actor()
      )

    result
  end

  describe "TN-3 TN-6 sub-tenants mapped from Access organizations" do
    test "TN-6: a repeated mapping is unchanged, a rename updates", %{tenant: t} do
      id = Relay.Id.generate()
      assert {:created, ^id, v1} = upsert(t.live, id, "Branch")
      assert {:unchanged, ^id, ^v1} = upsert(t.live, id, "Branch")
      assert {:updated, ^id, v2} = upsert(t.live, id, "Renamed")
      assert v2 > v1
    end

    test "TN-6: one sub-tenant keeps its identifier in both environments as two rows", %{
      tenant: t
    } do
      id = Relay.Id.generate()
      assert {:created, ^id, _} = upsert(t.live, id, "Branch")
      assert {:created, ^id, _} = upsert(t.test, id, "Branch")
    end

    test "TN-3: archiving is a state change and a later mapping does not revive it", %{tenant: t} do
      id = TenantFixture.subtenant!(t.live)
      digest = TenantFixture.digest()
      actor = TenantFixture.actor()

      assert {:ok, :archived} = Relay.Tenancy.archive_subtenant(t.live, id, digest, actor)
      assert {:ok, :already_archived} = Relay.Tenancy.archive_subtenant(t.live, id, digest, actor)
      assert {:archived, ^id, _} = upsert(t.live, id, "Branch")

      assert {:ok, :not_found} =
               Relay.Tenancy.archive_subtenant(t.live, Relay.Id.generate(), digest, actor)
    end

    test "TN-15: another tenant's sub-tenant is not found", %{tenant: t} do
      other = TenantFixture.tenant!()
      id = TenantFixture.subtenant!(other.live)

      assert {:ok, :not_found} =
               Relay.Tenancy.archive_subtenant(
                 t.live,
                 id,
                 TenantFixture.digest(),
                 TenantFixture.actor()
               )
    end
  end

  describe "MKT-10 no plan gate" do
    test "MKT-10: sub-tenants are not limited by a plan or tier", %{tenant: t} do
      for _ <- 1..20 do
        assert {:created, _, _} = upsert(t.live, Relay.Id.generate(), "Branch")
      end
    end
  end
end
