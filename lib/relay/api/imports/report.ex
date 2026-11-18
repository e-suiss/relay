defmodule Relay.Api.Imports.Report do
  @moduledoc """
  The report of an import as it is built (OP-96): counts of written and unchanged lines, the invalid bucket and the skipped lines with their codes, identity conflicts, the records each written line leaves for traceability (OP-55 (6)) and the sections of the type. Values of personal fields never enter it; only line numbers and codes do. Each list keeps at most `import.max_report_items` entries and says whether more were left out.
  """

  @max_items Relay.Limits.fetch!(["import", "max_report_items"])
  @sections [:consents, :suppression_check, :devices, :templates, :confirmations]

  @type t :: %{
          lines: non_neg_integer(),
          written: non_neg_integer(),
          unchanged: non_neg_integer(),
          invalid: [{pos_integer(), String.t()}],
          skipped: [{pos_integer(), String.t()}],
          conflicts: [{String.t(), [non_neg_integer()]}],
          records: [tuple()],
          sections: map()
        }

  # OP-96
  @doc "An empty report of an upload of `lines` lines."
  @spec new(non_neg_integer()) :: t()
  def new(lines) do
    %{
      lines: lines,
      written: 0,
      unchanged: 0,
      invalid: [],
      skipped: [],
      conflicts: [],
      records: [],
      sections: Map.new(@sections, &{&1, nil})
    }
  end

  # OP-96
  @doc "Puts a line in the invalid bucket with its code."
  @spec invalid(t(), pos_integer(), String.t()) :: t()
  def invalid(report, line, code), do: %{report | invalid: [{line, code} | report.invalid]}

  # OP-96
  @doc "Records a line that was skipped on purpose, with its code."
  @spec skipped(t(), pos_integer(), String.t()) :: t()
  def skipped(report, line, code), do: %{report | skipped: [{line, code} | report.skipped]}

  # OP-55 (5)
  @doc "Records an identity conflict of `field` between lines (0 stands for an existing subscriber)."
  @spec conflict(t(), String.t(), [non_neg_integer()]) :: t()
  def conflict(report, field, lines),
    do: %{report | conflicts: [{field, Enum.sort(lines)} | report.conflicts]}

  # OP-96
  @doc "Counts a written line and keeps its traceability record, if any."
  @spec written(t(), tuple() | nil) :: t()
  def written(report, record), do: keep(%{report | written: report.written + 1}, record)

  # OP-96
  @doc "Counts a line whose write changed nothing and keeps its traceability record, if any."
  @spec unchanged(t(), tuple() | nil) :: t()
  def unchanged(report, record), do: keep(%{report | unchanged: report.unchanged + 1}, record)

  defp keep(report, nil), do: report
  defp keep(report, record), do: %{report | records: [record | report.records]}

  # OP-96
  @doc "Sets a section of the type."
  @spec section(t(), atom(), term()) :: t()
  def section(report, name, value) when name in @sections,
    do: %{report | sections: Map.put(report.sections, name, value)}

  # OP-96
  # TN-58
  @doc "The report document stored with the import, with the data residency metadata of the environment's provider accounts."
  @spec document(t(), [map()]) :: map()
  def document(report, providers) do
    {invalid, cut_invalid} = cap(Enum.sort(report.invalid))
    {skipped, cut_skipped} = cap(Enum.sort(report.skipped))
    {conflicts, cut_conflicts} = cap(Enum.sort(report.conflicts))
    {templates, cut_templates} = cap_section(report.sections.templates)
    {confirmations, cut_confirmations} = cap_section(report.sections.confirmations)

    %{
      "counts" => %{
        "lines" => report.lines,
        "written" => report.written,
        "unchanged" => report.unchanged,
        "skipped" => length(report.skipped),
        "invalid" => length(report.invalid),
        "conflicts" => length(report.conflicts)
      },
      "invalid" => Enum.map(invalid, &line_code/1),
      "conflicts" => Enum.map(conflicts, &conflict_view/1),
      "skipped" => Enum.map(skipped, &line_code/1),
      "truncated" =>
        cut_invalid or cut_skipped or cut_conflicts or cut_templates or cut_confirmations,
      "consents" => report.sections.consents,
      "suppression_check" => report.sections.suppression_check,
      "devices" => report.sections.devices,
      "templates" => templates,
      "confirmations" => confirmations,
      "data_residency" => %{"providers" => providers}
    }
  end

  defp line_code({line, code}), do: %{"line" => line, "code" => code}

  defp conflict_view({field, lines}), do: %{"field" => field, "lines" => lines}

  defp cap_section(nil), do: {nil, false}
  defp cap_section(list), do: list |> Enum.sort_by(& &1["line"]) |> cap()

  defp cap(list) when length(list) > @max_items, do: {Enum.take(list, @max_items), true}
  defp cap(list), do: {list, false}
end
