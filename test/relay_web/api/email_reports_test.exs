defmodule RelayWeb.Api.EmailReportsTest do
  use Relay.DataCase, async: false

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  defp dmarc(report_id, pass, fail) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <feedback>
      <report_metadata>
        <org_name>Yahoo</org_name><report_id>#{report_id}</report_id>
        <date_range><begin>1800000000</begin><end>1800086399</end></date_range>
      </report_metadata>
      <policy_published><domain>reports.example</domain><p>reject</p></policy_published>
      <record>
        <row><source_ip>203.0.113.1</source_ip><count>#{pass}</count>
          <policy_evaluated><disposition>none</disposition><dkim>pass</dkim><spf>pass</spf></policy_evaluated>
        </row>
        <identifiers><header_from>reports.example</header_from></identifiers>
      </record>
      <record>
        <row><source_ip>198.51.100.2</source_ip><count>#{fail}</count>
          <policy_evaluated><disposition>reject</disposition><dkim>fail</dkim><spf>fail</spf></policy_evaluated>
        </row>
        <identifiers><header_from>reports.example</header_from></identifiers>
      </record>
    </feedback>
    """
  end

  defp tls do
    %{
      "organization-name" => "Mail Corp",
      "date-range" => %{
        "start-datetime" => "2027-01-15T00:00:00Z",
        "end-datetime" => "2027-01-15T23:59:59Z"
      },
      "report-id" => "tls-1",
      "policies" => [
        %{
          "policy" => %{"policy-type" => "sts", "policy-domain" => "reports.example"},
          "summary" => %{
            "total-successful-session-count" => 90,
            "total-failure-session-count" => 10
          },
          "failure-details" => [
            %{"result-type" => "validation-failure", "failed-session-count" => 10}
          ]
        }
      ]
    }
  end

  setup do
    tenant = TenantFixture.tenant!()
    %{scope: tenant.live, token: F.token(tenant.live)}
  end

  defp upload(token, kind, encoding, content) do
    body = %{"kind" => kind, "encoding" => encoding, "content" => Base.encode64(content)}
    F.request(:post, "/v1/email_reports", token, body)
  end

  defp summary(token, query),
    do: F.body(F.request(:get, "/v1/email_reports/summary?" <> query, token), 200)

  describe "CH-46 DMARC aggregate and TLS report intake" do
    test "CH-46: a report is stored once and an upload of the same report answers 200", ctx do
      xml = dmarc("r-1", 40, 2)
      created = F.body(upload(ctx.token, "dmarc_aggregate", "gzip", :zlib.gzip(xml)), 201)

      assert %{"object" => "email_report", "kind" => "dmarc_aggregate"} = created
      assert %{"reporter" => "Yahoo", "report_id" => "r-1"} = created
      assert created["domain"] == "reports.example"
      assert created["summary"]["dmarc_fail"] == 2

      again = F.body(upload(ctx.token, "dmarc_aggregate", "xml", xml), 200)
      assert again["id"] == created["id"]
    end

    test "CH-46: a domain's summary sums DMARC and TLS reports separately", ctx do
      F.body(upload(ctx.token, "dmarc_aggregate", "xml", dmarc("r-1", 40, 2)), 201)
      F.body(upload(ctx.token, "dmarc_aggregate", "xml", dmarc("r-2", 10, 1)), 201)
      F.body(upload(ctx.token, "tls_rpt", "json", Jason.encode!(tls())), 201)

      window = "domain=reports.example&from=2026-12-01T00:00:00Z&to=2027-02-01T00:00:00Z"
      result = summary(ctx.token, window)

      assert %{"object" => "email_report_summary", "truncated" => false} = result

      assert %{"reports" => 2, "messages" => 53, "dmarc_pass" => 50, "dmarc_fail" => 3} =
               result["dmarc"]

      assert result["dmarc"]["dispositions"]["reject"] == 3

      assert %{"reports" => 1, "successful_sessions" => 90, "failed_sessions" => 10} =
               result["tls"]

      assert result["tls"]["failures"] == %{"validation-failure" => 10}
      assert result["reporters"] == ["Mail Corp", "Yahoo"]

      other = summary(ctx.token, String.replace(window, "reports.example", "other.example"))
      assert other["dmarc"]["reports"] == 0
    end

    test "CH-46: unreadable content is a field error", ctx do
      problem = F.body(upload(ctx.token, "dmarc_aggregate", "xml", "<feedback>"), 422)
      assert [%{"pointer" => "/content", "code" => "invalid_format"}] = problem["errors"]

      body = %{"kind" => "tls_rpt", "encoding" => "json", "content" => "%%%"}
      problem = F.body(F.request(:post, "/v1/email_reports", ctx.token, body), 422)
      assert [%{"pointer" => "/content"}] = problem["errors"]
    end
  end
end
