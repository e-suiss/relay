defmodule Relay.Channels.Email.Reports do
  @moduledoc """
  The parsing of e-mail authentication reports a tenant hands to Relay (CH-46): DMARC aggregate reports (RFC 7489 Appendix C, XML) and SMTP TLS reports (RFC 8460 §4, JSON). Relay receives no mail, so a report reaches it as an upload of the attachment the receiver sent, as written (`xml` or `json`), gzip-compressed (`gzip`) or as a ZIP archive of one file (`zip`).

  A report is read into its reporter, report identifier, policy domain, date range, records and a summary of counts:

    * DMARC: one record per row (`source_ip`, `count`, the evaluated `disposition`, `dkim` and `spf`, `header_from` and the raw DKIM and SPF results); the summary counts messages, messages that pass DMARC (aligned DKIM or SPF passes), those that fail, the dispositions and the published policy.
    * TLS-RPT: one record per policy (`policy_type`, `policy_domain`, successful and failed session counts and the failure details); the summary counts the sessions and the failures by result type. The policy domain of the first policy names the report's domain.

  Decompressed content is capped at 10 MiB and 10,000 records. XML with a document type declaration or an entity is refused before parsing, and the parser never fetches an external entity.
  """

  @max_bytes 10 * 1024 * 1024
  @max_records 10_000
  @max_text 256
  @domain ~r/\A(?=.{1,253}\z)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/
  @dispositions ["none", "quarantine", "reject"]
  @policy_fields ["p", "sp", "pct", "adkim", "aspf"]

  @type kind :: :dmarc_aggregate | :tls_rpt
  @type encoding :: :xml | :json | :gzip | :zip
  @type report :: %{
          kind: kind(),
          reporter: String.t(),
          report_ref: String.t(),
          domain: String.t(),
          begin_at: DateTime.t(),
          end_at: DateTime.t(),
          summary: map(),
          records: [map()]
        }

  # CH-46
  @doc "Parses an uploaded report of `kind` in `encoding`; `:invalid_report` for content that is not a readable report and `:report_too_large` beyond the caps."
  @spec parse(kind(), encoding(), binary()) ::
          {:ok, report()} | {:error, :invalid_report | :report_too_large}
  def parse(kind, encoding, content) when is_binary(content) do
    with {:ok, data} <- unpack(encoding, content) do
      case kind do
        :dmarc_aggregate -> dmarc(data)
        :tls_rpt -> tls(data)
      end
    end
  end

  defp unpack(encoding, content) when encoding in [:xml, :json], do: bounded(content)
  defp unpack(:gzip, content), do: gunzip(content)
  defp unpack(:zip, content), do: unzip(content)

  defp bounded(data) when byte_size(data) <= @max_bytes, do: {:ok, data}
  defp bounded(_data), do: {:error, :report_too_large}

  defp gunzip(content) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      inflate(z, :zlib.safeInflate(z, content), [], 0)
    rescue
      _error -> {:error, :invalid_report}
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, {status, out}, acc, size) do
    size = size + IO.iodata_length(out)

    cond do
      size > @max_bytes -> {:error, :report_too_large}
      status == :finished -> {:ok, [out | acc] |> Enum.reverse() |> IO.iodata_to_binary()}
      IO.iodata_length(out) == 0 -> {:error, :invalid_report}
      true -> inflate(z, :zlib.safeInflate(z, []), [out | acc], size)
    end
  end

  defp unzip(content) do
    with {:ok, [_comment | files]} <- :zip.list_dir(content),
         [{:zip_file, name, info, _comment, _offset, _size}] <- files,
         true <- elem(info, 1) <= @max_bytes,
         {:ok, [{^name, data}]} <- :zip.unzip(content, [:memory, {:file_list, [name]}]) do
      bounded(data)
    else
      false -> {:error, :report_too_large}
      _other -> {:error, :invalid_report}
    end
  rescue
    _error -> {:error, :invalid_report}
  end

  # CH-46
  defp dmarc(data) do
    with {:ok, {"feedback", _children, _text} = root} <- xml(data),
         meta = child(root, "report_metadata"),
         policy = child(root, "policy_published"),
         {:ok, reporter} <- required(text(meta, ["org_name"])),
         {:ok, report_ref} <- required(text(meta, ["report_id"])),
         {:ok, domain} <- domain(text(policy, ["domain"])),
         {:ok, begin_at} <- unix(text(meta, ["date_range", "begin"])),
         {:ok, end_at} <- unix(text(meta, ["date_range", "end"])),
         {:ok, records} <- records(children(root, "record")) do
      {:ok,
       %{
         kind: :dmarc_aggregate,
         reporter: reporter,
         report_ref: report_ref,
         domain: domain,
         begin_at: begin_at,
         end_at: end_at,
         summary: dmarc_summary(policy, records),
         records: records
       }}
    else
      _invalid -> {:error, :invalid_report}
    end
  end

  defp records(nodes) when length(nodes) > @max_records, do: :error

  defp records(nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      case record(node) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp record(node) do
    auth = child(node, "auth_results")

    case Integer.parse(text(node, ["row", "count"]) || "") do
      {count, ""} when count >= 0 ->
        {:ok,
         %{
           "source_ip" => text(node, ["row", "source_ip"]),
           "count" => count,
           "disposition" => text(node, ["row", "policy_evaluated", "disposition"]),
           "dkim" => text(node, ["row", "policy_evaluated", "dkim"]),
           "spf" => text(node, ["row", "policy_evaluated", "spf"]),
           "header_from" => text(node, ["identifiers", "header_from"]),
           "dkim_results" => for(n <- children(auth, "dkim"), do: text(n, ["result"])),
           "spf_results" => for(n <- children(auth, "spf"), do: text(n, ["result"]))
         }}

      _other ->
        :error
    end
  end

  defp dmarc_summary(policy, records) do
    messages = count(records, fn _record -> true end)
    pass = count(records, &(&1["dkim"] == "pass" or &1["spf"] == "pass"))
    dispositions = Map.new(@dispositions, &{&1, disposition(records, &1)})

    %{
      "messages" => messages,
      "dmarc_pass" => pass,
      "dmarc_fail" => messages - pass,
      "dispositions" => dispositions,
      "policy" => Map.new(@policy_fields, &{&1, text(policy, [&1])})
    }
  end

  defp disposition(records, name), do: count(records, &(&1["disposition"] == name))

  defp count(records, keep?),
    do: records |> Enum.filter(keep?) |> Enum.map(& &1["count"]) |> Enum.sum()

  # CH-46
  defp tls(data) do
    with {:ok, %{} = json} <- Jason.decode(data),
         {:ok, reporter} <- required(json["organization-name"]),
         {:ok, report_ref} <- required(json["report-id"]),
         %{"start-datetime" => start, "end-datetime" => stop} <- json["date-range"],
         {:ok, begin_at, _offset} <- DateTime.from_iso8601(start),
         {:ok, end_at, _offset} <- DateTime.from_iso8601(stop),
         [_ | _] = policies when length(policies) <= @max_records <- json["policies"],
         {:ok, records} <- policies(policies),
         {:ok, domain} <- domain(hd(records)["policy_domain"]) do
      {:ok,
       %{
         kind: :tls_rpt,
         reporter: reporter,
         report_ref: report_ref,
         domain: domain,
         begin_at: begin_at,
         end_at: end_at,
         summary: tls_summary(records),
         records: records
       }}
    else
      _invalid -> {:error, :invalid_report}
    end
  end

  defp policies(policies) do
    records = Enum.map(policies, &policy/1)
    if Enum.all?(records, &is_map/1), do: {:ok, records}, else: :error
  end

  defp policy(%{"policy" => %{} = policy, "summary" => %{} = summary} = entry) do
    successful = summary["total-successful-session-count"]
    failed = summary["total-failure-session-count"]
    details = Map.get(entry, "failure-details", [])

    if count?(successful) and count?(failed) and is_list(details) do
      %{
        "policy_type" => short(policy["policy-type"]),
        "policy_domain" => short(policy["policy-domain"]),
        "successful" => successful,
        "failed" => failed,
        "failures" => Enum.flat_map(details, &failure/1)
      }
    end
  end

  defp policy(_entry), do: nil

  defp failure(%{"result-type" => type} = detail) when is_binary(type) do
    count = detail["failed-session-count"]

    [
      %{
        "result_type" => short(type),
        "sending_mta_ip" => short(detail["sending-mta-ip"]),
        "receiving_mx_hostname" => short(detail["receiving-mx-hostname"]),
        "receiving_ip" => short(detail["receiving-ip"]),
        "failed_session_count" => if(count?(count), do: count, else: 0)
      }
    ]
  end

  defp failure(_detail), do: []

  defp tls_summary(records) do
    failures =
      records
      |> Enum.flat_map(& &1["failures"])
      |> Enum.group_by(& &1["result_type"], & &1["failed_session_count"])
      |> Map.new(fn {type, counts} -> {type, Enum.sum(counts)} end)

    %{
      "successful_sessions" => records |> Enum.map(& &1["successful"]) |> Enum.sum(),
      "failed_sessions" => records |> Enum.map(& &1["failed"]) |> Enum.sum(),
      "failures" => failures
    }
  end

  defp count?(n), do: is_integer(n) and n >= 0

  defp short(value) when is_binary(value), do: String.slice(value, 0, @max_text)
  defp short(_value), do: nil

  defp required(value) when is_binary(value) and value != "",
    do: {:ok, String.slice(value, 0, @max_text)}

  defp required(_value), do: :error

  defp domain(value) when is_binary(value) do
    domain = value |> String.trim() |> String.trim_trailing(".") |> String.downcase()
    if Regex.match?(@domain, domain), do: {:ok, domain}, else: :error
  end

  defp domain(_value), do: :error

  defp unix(value) do
    with {seconds, ""} <- Integer.parse(value || ""),
         {:ok, at} <- DateTime.from_unix(seconds) do
      {:ok, at}
    else
      _other -> :error
    end
  end

  defp xml(data) do
    if String.contains?(data, ["<!DOCTYPE", "<!doctype", "<!ENTITY", "<!entity"]) do
      :error
    else
      opts = [
        event_fun: &event/3,
        event_state: [{"#root", [], []}],
        external_entities: :none
      ]

      case :xmerl_sax_parser.stream(data, opts) do
        {:ok, [{"#root", [root], _text}], _rest} -> {:ok, root}
        _other -> :error
      end
    end
  rescue
    _error -> :error
  end

  defp event({:startElement, _uri, name, _qname, _attributes}, _location, stack),
    do: [{List.to_string(name), [], []} | stack]

  defp event({:characters, chars}, _location, [{name, children, text} | rest]),
    do: [{name, children, [chars | text]} | rest]

  defp event({:endElement, _uri, _name, _qname}, _location, [node, parent | rest]) do
    {name, children, text} = node
    done = {name, Enum.reverse(children), text |> Enum.reverse() |> to_string() |> String.trim()}
    {parent_name, siblings, parent_text} = parent
    [{parent_name, [done | siblings], parent_text} | rest]
  end

  defp event(_event, _location, stack), do: stack

  defp child(nil, _name), do: nil
  defp child({_name, children, _text}, name), do: Enum.find(children, &(elem(&1, 0) == name))

  defp children(nil, _name), do: []

  defp children({_name, children, _text}, name),
    do: Enum.filter(children, &(elem(&1, 0) == name))

  defp text(node, []), do: node && elem(node, 2)
  defp text(node, [name | rest]), do: text(child(node, name), rest)
end
