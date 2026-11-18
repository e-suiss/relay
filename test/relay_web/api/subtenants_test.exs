defmodule RelayWeb.Api.SubtenantsTest do
  use Relay.DataCase, async: false

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  describe "TN-3 X-4 sub-tenant list" do
    test "TN-3: the sub-tenants of the environment are listed newest first" do
      tenant = TenantFixture.tenant!()
      first = TenantFixture.subtenant!(tenant.live)
      second = TenantFixture.subtenant!(tenant.live)
      _other = TenantFixture.subtenant!(tenant.test)

      body = F.body(F.request(:get, "/v1/subtenants", F.token(tenant.live)), 200)

      assert Enum.map(body["data"], & &1["id"]) ==
               [Relay.ExternalId.encode("stn", second), Relay.ExternalId.encode("stn", first)]

      assert [%{"object" => "subtenant", "name" => "Branch", "state" => "active"} | _] =
               body["data"]
    end
  end
end
