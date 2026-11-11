defmodule Relay.Api.EmailReports do
  @moduledoc """
  DMARC aggregate (RFC 7489) and SMTP TLS (RFC 8460) report intake in the server API (CH-46). Relay receives no mail: the tenant uploads the report attachment it received, as written or compressed, base64 encoded. A report is parsed and stored once per kind, reporter and report identifier; the same report uploaded again answers `200` with the stored report's identifier. The summary of a domain sums the stored reports whose date range ends in the window, DMARC and TLS separately.
  """

  alias Relay.Api.Gate
  alias Relay.Api.Views

  @kinds %{"dmarc_aggregate" => :dmarc_aggregate, "tls_rpt" => :tls_rpt}
  @encodings %{"xml" => :xml, "json" => :json, "gzip" => :gzip, "zip" => :zip}
  @window_days 30
  @max_window_days 366
  @max_reports 1000
  @dispositions ["none", "quarantine", "reject"]
  @window_detail "from is before to and at most #{@max_window_days} days earlier"

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # CH-46
  @doc "The API view of a stored or parsed report with its identifier."
  @spec view(Relay.Id.t(), map()) :: map()
  def view(id, report) do
    %{
      "object" => "email_report",
      "id" => Views.id("emr", id),
      "kind" => to_string(report.kind),
      "reporter" => report.reporter,
      "report_id" => report.report_ref,
      "domain" => report.domain,
      "begin_at" => report.begin_at,
      "end_at" => report.end_at,
      "record_count" => length(report.records),
      "summary" => report.summary
    }
  end

  # CH-46
  @doc "Parses and stores an uploaded report inside the request's transaction: `201` when it is new, `200` when the same report was stored before."
  @spec create(Relay.Scope.t(), map()) :: answer()
  def create(_scope, body) do
    kind = Map.fetch!(@kinds, body["kind"])
    encoding = Map.fetch!(@encodings, body["encoding"])

    with {:ok, content} <- base64(body["content"]),
         {:ok, report} <- parse(kind, encoding, content) do
      digest = :crypto.hash(:sha256, content)

      case Relay.Channels.record_email_report(report, digest) do
        {:recorded, id} -> {:ok, {201, [], view(id, report)}}
        {:duplicate, id} -> {:ok, {200, [], view(id, report)}}
      end
    end
  end

  defp base64(content) do
    case Base.decode64(content, ignore: :whitespace) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, Gate.field_error("/content", "invalid_format", "not base64")}
    end
  end

  defp parse(kind, encoding, content) do
    case Relay.Channels.parse_email_report(kind, encoding, content) do
      {:ok, report} ->
        {:ok, report}

      {:error, :report_too_large} ->
        {:error, Gate.field_error("/content", "too_long", "the report exceeds 10 MiB")}

      {:error, :invalid_report} ->
        {:error, Gate.field_error("/content", "invalid_format", "not a readable report")}
    end
  end

  # CH-46
  @doc "The summary of a domain's reports whose date range ends in `[from, to)` (default: the last #{@window_days} days), at most #{@max_reports} reports, in its own transaction."
  @spec summary(Relay.Scope.t(), map()) :: answer()
  def summary(scope, params) do
    with {:ok, domain} <- domain(params["domain"]),
         {:ok, to} <- time(params["to"], Relay.Clock.utc_now(), "/to"),
         {:ok, from} <- time(params["from"], DateTime.add(to, -@window_days, :day), "/from"),
         :ok <- window(from, to),
         {:ok, rows} <- reports(scope, domain, from, to) do
      {kept, rest} = Enum.split(rows, @max_reports)
      {dmarc, tls} = Enum.split_with(kept, &(&1["kind"] == "dmarc_aggregate"))

      body = %{
        "object" => "email_report_summary",
        "domain" => domain,
        "from" => from,
        "to" => to,
        "truncated" => rest != [],
        "dmarc" => dmarc_totals(dmarc),
        "tls" => tls_totals(tls),
        "reporters" => kept |> Enum.map(& &1["reporter"]) |> Enum.uniq() |> Enum.sort()
      }

      {:ok, {200, [], body}}
    end
  end

  defp reports(scope, domain, from, to) do
    case Relay.Channels.email_reports(scope, domain, from, to, @max_reports + 1) do
      {:ok, rows} -> {:ok, rows}
      {:error, _reason} -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  defp dmarc_totals(rows) do
    summaries = Enum.map(rows, & &1["summary"])

    %{
      "reports" => length(rows),
      "messages" => sum(summaries, ["messages"]),
      "dmarc_pass" => sum(summaries, ["dmarc_pass"]),
      "dmarc_fail" => sum(summaries, ["dmarc_fail"]),
      "dispositions" => Map.new(@dispositions, &{&1, sum(summaries, ["dispositions", &1])})
    }
  end

  defp tls_totals(rows) do
    summaries = Enum.map(rows, & &1["summary"])

    failures =
      summaries
      |> Enum.flat_map(&Map.to_list(Map.get(&1, "failures", %{})))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {type, counts} -> {type, Enum.sum(counts)} end)

    %{
      "reports" => length(rows),
      "successful_sessions" => sum(summaries, ["successful_sessions"]),
      "failed_sessions" => sum(summaries, ["failed_sessions"]),
      "failures" => failures
    }
  end

  defp sum(summaries, path) do
    summaries
    |> Enum.map(&get_in(&1, path))
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  defp domain(value) when is_binary(value) and value != "" do
    {:ok, value |> String.trim_trailing(".") |> String.downcase()}
  end

  defp domain(_value), do: {:error, Gate.field_error("/domain", "required", "name a domain")}

  defp time(nil, default, _pointer), do: {:ok, default}

  defp time(value, _default, pointer) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _other -> {:error, Gate.field_error(pointer, "invalid_format", "an RFC 3339 time")}
    end
  end

  defp window(from, to) do
    days = DateTime.diff(to, from, :day)

    if DateTime.compare(from, to) == :lt and days <= @max_window_days,
      do: :ok,
      else: {:error, Gate.field_error("/from", "invalid_format", @window_detail)}
  end
end
