defmodule Relay.Channels.Email.ReportsTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Email.Reports

  @dmarc """
  <?xml version="1.0" encoding="UTF-8" ?>
  <feedback>
    <report_metadata>
      <org_name>google.com</org_name>
      <email>noreply-dmarc-support@google.com</email>
      <report_id>4711</report_id>
      <date_range><begin>1798675200</begin><end>1798761599</end></date_range>
    </report_metadata>
    <policy_published>
      <domain>Example.COM</domain><adkim>r</adkim><aspf>r</aspf><p>none</p><sp>none</sp><pct>100</pct>
    </policy_published>
    <record>
      <row>
        <source_ip>203.0.113.10</source_ip><count>12</count>
        <policy_evaluated><disposition>none</disposition><dkim>pass</dkim><spf>fail</spf></policy_evaluated>
      </row>
      <identifiers><header_from>example.com</header_from></identifiers>
      <auth_results><dkim><domain>example.com</domain><result>pass</result></dkim><spf><domain>example.com</domain><result>softfail</result></spf></auth_results>
    </record>
    <record>
      <row>
        <source_ip>198.51.100.7</source_ip><count>3</count>
        <policy_evaluated><disposition>quarantine</disposition><dkim>fail</dkim><spf>fail</spf></policy_evaluated>
      </row>
      <identifiers><header_from>example.com</header_from></identifiers>
      <auth_results><spf><domain>spoof.example</domain><result>fail</result></spf></auth_results>
    </record>
  </feedback>
  """

  @tls %{
    "organization-name" => "Company-X",
    "date-range" => %{
      "start-datetime" => "2026-12-01T00:00:00Z",
      "end-datetime" => "2026-12-01T23:59:59Z"
    },
    "contact-info" => "sts-reporting@company-x.example",
    "report-id" => "5065427c-23d3-47ca-b6e0-946ea0e8c4be",
    "policies" => [
      %{
        "policy" => %{
          "policy-type" => "sts",
          "policy-string" => ["version: STSv1", "mode: testing"],
          "policy-domain" => "example.com",
          "mx-host" => ["*.mail.example.com"]
        },
        "summary" => %{
          "total-successful-session-count" => 5326,
          "total-failure-session-count" => 303
        },
        "failure-details" => [
          %{
            "result-type" => "certificate-expired",
            "sending-mta-ip" => "2001:db8:abcd:0012::1",
            "receiving-mx-hostname" => "mx1.mail.example.com",
            "failed-session-count" => 100
          },
          %{
            "result-type" => "starttls-not-supported",
            "sending-mta-ip" => "2001:db8:abcd:0013::1",
            "receiving-mx-hostname" => "mx2.mail.example.com",
            "receiving-ip" => "203.0.113.56",
            "failed-session-count" => 203
          }
        ]
      }
    ]
  }

  describe "CH-46 DMARC aggregate reports" do
    test "CH-46: a DMARC aggregate report is read into its records and summary" do
      assert {:ok, report} = Reports.parse(:dmarc_aggregate, :xml, @dmarc)

      assert %{kind: :dmarc_aggregate, reporter: "google.com", report_ref: "4711"} = report
      assert report.domain == "example.com"
      assert report.begin_at == DateTime.from_unix!(1_798_675_200)

      assert [first, second] = report.records
      assert %{"source_ip" => "203.0.113.10", "count" => 12, "dkim" => "pass"} = first
      assert first["spf_results"] == ["softfail"]
      assert second["disposition"] == "quarantine"

      assert %{"messages" => 15, "dmarc_pass" => 12, "dmarc_fail" => 3} = report.summary
      assert report.summary["dispositions"] == %{"none" => 12, "quarantine" => 3, "reject" => 0}
      assert report.summary["policy"]["p"] == "none"
    end

    test "CH-46: gzip and ZIP uploads are read like the XML itself" do
      {:ok, plain} = Reports.parse(:dmarc_aggregate, :xml, @dmarc)

      assert {:ok, ^plain} = Reports.parse(:dmarc_aggregate, :gzip, :zlib.gzip(@dmarc))

      {:ok, {_name, zip}} = :zip.create(~c"report.zip", [{~c"report.xml", @dmarc}], [:memory])
      assert {:ok, ^plain} = Reports.parse(:dmarc_aggregate, :zip, zip)
    end

    test "CH-46: a document type, broken XML or a truncated archive is refused" do
      doctype =
        String.replace(@dmarc, "<feedback>", "<!DOCTYPE feedback [<!ENTITY x \"y\">]><feedback>")

      for {encoding, content} <- [
            {:xml, doctype},
            {:xml, "<feedback><report_metadata>"},
            {:xml, String.replace(@dmarc, "<count>12</count>", "<count>many</count>")},
            {:gzip, binary_part(:zlib.gzip(@dmarc), 0, 40)},
            {:zip, "not a zip"}
          ] do
        assert {:error, :invalid_report} = Reports.parse(:dmarc_aggregate, encoding, content)
      end
    end
  end

  describe "CH-46 TLS reports" do
    test "CH-46: an RFC 8460 report is read into its policies and failure counts" do
      assert {:ok, report} = Reports.parse(:tls_rpt, :json, Jason.encode!(@tls))

      assert %{kind: :tls_rpt, reporter: "Company-X", domain: "example.com"} = report
      assert report.report_ref == "5065427c-23d3-47ca-b6e0-946ea0e8c4be"
      assert [%{"policy_type" => "sts", "successful" => 5326, "failed" => 303}] = report.records

      assert report.summary == %{
               "successful_sessions" => 5326,
               "failed_sessions" => 303,
               "failures" => %{"certificate-expired" => 100, "starttls-not-supported" => 203}
             }

      gzip = :zlib.gzip(Jason.encode!(@tls))
      assert {:ok, ^report} = Reports.parse(:tls_rpt, :gzip, gzip)
    end

    test "CH-46: a TLS report without its required members is refused" do
      for broken <- [Map.delete(@tls, "report-id"), Map.put(@tls, "policies", [])] do
        assert {:error, :invalid_report} = Reports.parse(:tls_rpt, :json, Jason.encode!(broken))
      end

      assert {:error, :invalid_report} = Reports.parse(:tls_rpt, :json, "{")
    end
  end
end
