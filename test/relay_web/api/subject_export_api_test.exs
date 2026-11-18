defmodule RelayWeb.Api.SubjectExportApiTest do
  use Relay.DataCase, async: false

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, token: F.token(tenant.live)}
  end

  defp audited(scope) do
    {:ok, rows} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.scoped_query!(
          """
          SELECT tenant_id, environment, target_type, target_id FROM relay.audit_log
          WHERE action = 'subject.exported'
          """,
          []
        ).rows
      end)

    Enum.map(rows, &Enum.drop(&1, 2))
  end

  describe "OP-26 per-person export" do
    test "OP-26, OP-86: one subscriber's data comes back as JSON and is audited", ctx do
      id = "user-" <> TenantFixture.random()

      created =
        F.body(
          F.request(:post, "/v1/subscribers", ctx.token, %{
            "external_id" => id,
            "email" => "ayse@example.com"
          }),
          201
        )

      export = F.body(F.request(:get, "/v1/subscribers/#{id}/export", ctx.token), 200)

      assert %{
               "object" => "subscriber_export",
               "subscriber" => %{"id" => sub, "external_id" => ^id},
               "deliveries" => [],
               "truncated" => false
             } = export

      assert sub == created["id"]
      assert audited(ctx.tenant.live) == [["subscriber", sub]]
    end

    test "OP-26: an unknown subscriber is not found and nothing is audited", ctx do
      conn = F.request(:get, "/v1/subscribers/nobody-#{TenantFixture.random()}/export", ctx.token)
      assert F.body(conn, 404)["code"] == "subscriber_not_found"
      assert audited(ctx.tenant.live) == []
    end

    test "OP-26: the export needs the subscribers scope", ctx do
      token = F.token(ctx.tenant.live, ["read"])
      conn = F.request(:get, "/v1/subscribers/anyone/export", token)
      assert F.body(conn, 403)["code"] == "auth_insufficient_scope"
    end
  end
end
