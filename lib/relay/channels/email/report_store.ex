defmodule Relay.Channels.Email.ReportStore do
  @moduledoc """
  Data access of the e-mail authentication reports (CH-46): a parsed DMARC aggregate or TLS-RPT report is appended once per tenant environment, kind, reporter and report identifier through `relay_fn.email_report_record`; a report sent again is a duplicate of the stored one. The reports of a domain are read by the end of their date range. Every function runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  @kinds %{dmarc_aggregate: "dmarc_aggregate", tls_rpt: "tls_rpt"}

  # CH-46
  @doc "Appends a parsed report with the digest of its uploaded content; returns `:recorded` or `:duplicate` with the stored report's identifier."
  @spec record(Relay.Channels.Email.Reports.report(), <<_::256>>) ::
          {:recorded | :duplicate, Relay.Id.t()}
  def record(report, <<_::256>> = digest) do
    [row] =
      Repo.call!("relay_fn.email_report_record", [
        Relay.Id.generate(),
        Map.fetch!(@kinds, report.kind),
        report.reporter,
        report.report_ref,
        report.domain,
        report.begin_at,
        report.end_at,
        digest,
        report.summary,
        report.records
      ])

    {Repo.code!(row["result"], [:recorded, :duplicate]), row["email_report_id"]}
  end

  # CH-46
  @doc "The reports of a domain whose date range ends in `[from, to)`, newest first, at most `limit`: identifier, kind, reporter, report identifier, date range and summary."
  @spec reports(String.t(), DateTime.t(), DateTime.t(), pos_integer()) :: [map()]
  def reports(domain, from, to, limit) do
    sql = """
    SELECT tenant_id, environment, id, kind, reporter, report_ref, begin_at, end_at, summary,
      record_count, created_at
    FROM relay.email_reports
    WHERE domain = $1 AND end_at >= $2 AND end_at < $3
    ORDER BY end_at DESC, id DESC
    LIMIT $4
    """

    %Postgrex.Result{columns: columns, rows: rows} =
      Repo.scoped_query!(sql, [domain, from, to, limit])

    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
