defmodule RelayWeb.TlsReportControllerTest do
  use Relay.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias RelayTest.TenantFixture

  @endpoint RelayWeb.Endpoint

  defp report(id) do
    Jason.encode!(%{
      "organization-name" => "Mail Corp",
      "date-range" => %{
        "start-datetime" => "2026-12-01T00:00:00Z",
        "end-datetime" => "2026-12-01T23:59:59Z"
      },
      "report-id" => id,
      "policies" => [
        %{
          "policy" => %{"policy-type" => "sts", "policy-domain" => "tls.example"},
          "summary" => %{
            "total-successful-session-count" => 10,
            "total-failure-session-count" => 0
          }
        }
      ]
    })
  end

  defp path(scope) do
    "/tlsrpt/v1/" <> Relay.ExternalId.encode("ten", scope.tenant_id) <> "/live"
  end

  defp post_report(path, type, body) do
    build_conn()
    |> put_req_header("content-type", type)
    |> post(path, body)
  end

  describe "CH-46 CH-87 the HTTPS TLS-RPT intake" do
    test "CH-87: a report posted without credentials is stored once" do
      scope = TenantFixture.tenant!().live

      assert post_report(path(scope), "application/tlsrpt+json", report("r-1")).status == 202

      gzip = :zlib.gzip(report("r-1"))
      assert post_report(path(scope), "application/tlsrpt+gzip", gzip).status == 202

      {:ok, rows} =
        Relay.Channels.email_reports(
          scope,
          "tls.example",
          ~U[2026-11-01 00:00:00Z],
          ~U[2027-01-01 00:00:00Z],
          10
        )

      assert [%{"kind" => "tls_rpt", "reporter" => "Mail Corp"}] = rows
    end

    test "CH-87: another media type, an unreadable report or an unknown tenant is refused" do
      scope = TenantFixture.tenant!().live

      assert post_report(path(scope), "application/json", report("r-2")).status == 415
      assert post_report(path(scope), "application/tlsrpt+json", "{").status == 400

      unknown = "/tlsrpt/v1/" <> Relay.ExternalId.encode("ten", Relay.Id.generate()) <> "/live"
      assert post_report(unknown, "application/tlsrpt+json", report("r-3")).status == 404
      assert post_report("/tlsrpt/v1/bad/live", "application/tlsrpt+json", "{}").status == 404
    end
  end
end
