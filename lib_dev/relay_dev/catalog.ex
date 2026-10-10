defmodule RelayDev.Catalog do
  @moduledoc """
  The tracked rule catalog. The specification is not tracked in the repository, so CI sees rule IDs through `conformance/catalog/rules.json`: ID, section, status, short English title, the stage whose boundaries verify it and whether its acceptance fields are written. `generate/2` rebuilds the catalog from a local specification and keeps existing titles; `check/1` verifies tests against it.
  """

  alias RelayDev.Lint
  alias RelayDev.Lint.Violation

  @rules "conformance/catalog/rules.json"
  @progress "conformance/catalog/progress.json"
  @families ~w(MD F L MKT C INV E X API WF TP CH PC DS IN WH AG TN T OP OQ)
  @id_regex Regex.compile!("\\b(?:#{Enum.join(@families, "|")})-\\d+\\b")
  @statuses %{
    "KANONİK DEĞİŞMEZ" => "canonical_invariant",
    "MERKEZİ KARAR" => "central",
    "FROZEN (ürün)" => "frozen_product",
    "FROZEN (teknik)" => "frozen_technical",
    "FROZEN (landscape)" => "frozen_landscape",
    "POLICY DEFAULT" => "policy_default",
    "ENGINEERING ASSUMPTION" => "engineering_assumption",
    "WATCH" => "watch",
    "KAPSAM DIŞI" => "out_of_scope"
  }

  @type rule :: %{required(String.t()) => term()}

  # T-81
  @doc "Builds catalog entries from the specification directory, keeping titles from `previous`."
  @spec generate(Path.t(), [rule()]) :: [rule()]
  def generate(spec_dir, previous \\ []) do
    titles = Map.new(previous, &{&1["id"], &1["title"]})

    sections =
      spec_dir |> Path.join("[0-2][0-9]-*.md") |> Path.wildcard() |> Enum.reject(&skip_section?/1)

    appendix = File.read!(Path.join(spec_dir, "appendix-b-feature-inventory.md"))
    verify = verify_stages(appendix)
    acceptance = acceptance(Enum.map(sections, &File.read!/1))

    sections
    |> Enum.flat_map(&rows/1)
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {_id, [first | _] = found} -> merge(first, found) end)
    |> Enum.sort_by(&sort_key(&1.id))
    |> Enum.map(fn row ->
      %{
        "id" => row.id,
        "section" => row.section,
        "status" => row.status,
        "title" => non_empty(titles[row.id]) || row.title,
        "verify_stage" => verify[row.id],
        "acceptance" => Map.get(acceptance, row.id, "pending")
      }
    end)
  end

  defp merge(first, found) do
    status = Enum.find_value(found, & &1.status) || family_status(first.id)
    title = Enum.find_value(found, &non_empty(&1.title)) || ""
    %{first | status: status, title: title}
  end

  defp family_status("L-" <> _), do: "frozen_landscape"
  defp family_status("OQ-" <> _), do: "open_question"
  defp family_status(_), do: "unspecified"

  defp skip_section?(path), do: Path.basename(path) =~ ~r/^(00|21)-/

  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  defp sort_key(id) do
    [family, number] = String.split(id, "-")
    {Enum.find_index(@families, &(&1 == family)), String.to_integer(number)}
  end

  defp rows(path) do
    section =
      "§" <> (path |> Path.basename() |> String.split("-") |> hd() |> String.trim_leading("0"))

    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({nil, []}, fn line, {header, acc} ->
      cells = cells(line)

      cond do
        String.starts_with?(line, "|---") ->
          {header, acc}

        cells == [] ->
          {nil, acc}

        hd(cells) in ["ID", "OQ"] and "Kabul testi" not in cells ->
          {cells, acc}

        hd(cells) == "ID" ->
          {nil, acc}

        header && Regex.match?(~r/^#{@id_regex.source}$/, hd(cells)) ->
          {header, [row(header, cells, section) | acc]}

        true ->
          {header, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp cells(line) do
    if String.starts_with?(line, "|") and not String.starts_with?(line, "|---"),
      do:
        line |> String.trim() |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1),
      else: []
  end

  defp row(header, cells, section) do
    column = fn name -> Enum.find_index(header, &(&1 == name)) end

    status =
      case column.("Statü") do
        nil ->
          nil

        i ->
          cells
          |> Enum.at(i, "")
          |> String.split("·")
          |> hd()
          |> String.trim()
          |> then(&Map.get(@statuses, &1))
      end

    title =
      case column.("Kod adı") do
        nil -> ""
        i -> cells |> Enum.at(i, "") |> String.replace("`", "")
      end

    %{id: hd(cells), section: section, status: status, title: title}
  end

  defp verify_stages(appendix) do
    appendix
    |> String.split(~r/^### Aşama /m)
    |> tl()
    |> Enum.flat_map(fn chunk ->
      [stage | _] = String.split(chunk, " ", parts: 2)
      stage = String.to_integer(stage)

      chunk |> bounds() |> Enum.map(&{&1, stage})
    end)
    |> Enum.reduce(%{}, fn {id, stage}, acc -> Map.update(acc, id, stage, &min(&1, stage)) end)
  end

  defp bounds(chunk) do
    case String.split(chunk, "#### Bu aşamada doğrulanacak sınırlar") do
      [_, bounds] ->
        for line <- bounds |> String.split("\n---") |> hd() |> String.split("\n"),
            [_, ids] <- [Regex.run(~r/^- \*\*([^*]+)\*\*/, line)],
            [id] <- Regex.scan(@id_regex, ids),
            do: id

      _ ->
        []
    end
  end

  defp acceptance(contents) do
    for content <- contents,
        chunk <- tl(String.split(content, "| ID | Kabul testi |")),
        line <- chunk |> String.split("\n\n") |> hd() |> String.split("\n"),
        [ids, test | _] <- [cells(line)],
        Regex.match?(@id_regex, ids),
        [id] <- Regex.scan(@id_regex, ids),
        into: %{},
        do: {id, if(String.starts_with?(test, "doldurulacak"), do: "pending", else: "defined")}
  end

  @doc "Reads the tracked catalog."
  @spec read(Path.t()) :: [rule()]
  def read(root), do: Lint.read_json(root, @rules, [])

  @doc "Writes the tracked catalog."
  @spec write(Path.t(), [rule()]) :: :ok
  def write(root, rules) do
    File.write!(Path.join(root, @rules), Jason.encode!(rules, pretty: true) <> "\n")
  end

  @doc """
  Checks tests against the catalog: every rule ID named in a test exists, and every rule verified by a stage up to the enforced stage has a title and at least one test.
  """
  @spec check(Path.t()) :: [Violation.t()]
  def check(root) do
    rules = read(root)
    known = MapSet.new(rules, & &1["id"])
    enforced = Lint.read_json(root, @progress, %{})["enforced_stage"] || -1
    named = test_ids(root)

    unknown =
      for {id, {path, line}} <- named, not MapSet.member?(known, id) do
        %Violation{
          path: path,
          line: line,
          rule: "catalog",
          message: "test names unknown rule #{id}"
        }
      end

    uncovered =
      for %{"id" => id, "verify_stage" => stage} = rule <- rules,
          is_integer(stage),
          stage <= enforced,
          problem <- coverage_problems(rule, Map.has_key?(named, id)) do
        %Violation{
          path: @rules,
          line: 0,
          rule: "catalog",
          message: "#{id} (stage #{stage}): #{problem}"
        }
      end

    unknown ++ uncovered
  end

  defp coverage_problems(rule, tested?) do
    Enum.reject(
      [
        if(rule["title"] in [nil, ""], do: "missing English title"),
        if(not tested?, do: "no test names this rule")
      ],
      &is_nil/1
    )
  end

  defp test_ids(root) do
    for path <- Lint.files(root, ["test/**/*_test.exs"]),
        {line, no} <-
          root |> Path.join(path) |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        Regex.match?(~r/^\s*(test|describe|property)\s+"/, line),
        [id] <- Regex.scan(@id_regex, line),
        reduce: %{} do
      acc -> Map.put_new(acc, id, {path, no})
    end
  end
end
