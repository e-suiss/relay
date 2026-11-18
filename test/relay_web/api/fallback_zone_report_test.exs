defmodule RelayWeb.Api.FallbackZoneReportTest do
  use Relay.DataCase, async: false

  alias Relay.Policy.Live.Store
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  describe "X-6 WF-46 fallback time zone counts" do
    test "WF-46: sends in an inferred time zone are counted per day and source and reported" do
      tenant = TenantFixture.tenant!()

      {:ok, _counted} =
        Relay.Repo.in_scope(tenant.live, fn _status ->
          for source <- ["tenant_default", "tenant_default", "device"],
              do: :counted = Store.fallback_zone_count(source)
        end)

      today = Date.utc_today()
      query = "from=#{Date.to_iso8601(today)}&to=#{Date.to_iso8601(Date.add(today, 1))}"
      path = "/v1/reports/fallback_timezones?" <> query
      body = F.body(F.request(:get, path, F.token(tenant.live)), 200)

      assert body["object"] == "fallback_timezone_report"

      assert Enum.map(body["rows"], &{&1["source"], &1["deliveries"]}) ==
               [{"device", 1}, {"tenant_default", 2}]

      other = F.body(F.request(:get, path, F.token(tenant.test)), 200)
      assert other["rows"] == []
    end
  end
end
