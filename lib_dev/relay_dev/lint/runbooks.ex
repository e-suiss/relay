defmodule RelayDev.Lint.Runbooks do
  @moduledoc """
  Runbook lint. Every file under `runbooks/` (but its READMEs) starts with a YAML front matter block and an alert or procedure runbook carries the six sections `Symptom`, `Impact`, `Diagnosis`, `Decision tree`, `Mitigation` and `Fix and escalation` in that order, none of them empty. A shell block marked `state-changing` holds one command. A runbook whose `last_tested` is older than 183 days is unreliable. Every alert in `deploy/observability/alerts.yaml` points its `runbook_url` at an existing runbook, and every alert runbook is pointed at by the alerts it lists.
  """

  alias RelayDev.Lint.Violation

  @alerts "deploy/observability/alerts.yaml"
  @url_prefix "https://github.com/e-suiss/relay/blob/main/"
  @sections [
    "Symptom",
    "Impact",
    "Diagnosis",
    "Decision tree",
    "Mitigation",
    "Fix and escalation"
  ]
  @kinds ~w(alert procedure incident)
  @severities ~w(SEV1 SEV2 SEV3 SEV4)
  @tenant_scopes ~w(none one some all)
  @tested_by ~w(game_day incident none)
  @chat ~w(slack teams telegram discord)
  @channels ~w(all none push web_push email sms voice whatsapp in_app webhook) ++ @chat
  @common ~w(id kind last_tested tested_by)
  @runbook_fields ~w(severity channels tenant_scope alerts automation eta_minutes reversible)
  @max_age_days 183

  # OP-43
  # OP-83
  # OP-37 (6)
  @doc "Returns runbook violations under `root`. Options: `today:` (a `Date`, by default the current UTC date)."
  @spec run(Path.t(), keyword()) :: [Violation.t()]
  def run(root, opts \\ []) do
    today = Keyword.get_lazy(opts, :today, fn -> DateTime.to_date(Relay.Clock.utc_now()) end)

    parsed =
      for path <- RelayDev.Lint.files(root, ["runbooks/**/*.md"]),
          Path.basename(path) != "README.md" do
        parse(path, File.read!(Path.join(root, path)))
      end

    {pointers, alert_violations} = alerts(root)

    file_violations =
      Enum.flat_map(parsed, fn
        {:error, violations} -> violations
        {:ok, runbook} -> check(runbook, today)
      end)

    runbooks = for {:ok, runbook} <- parsed, do: runbook

    links = links(root, runbooks, pointers)
    file_violations ++ alert_violations ++ duplicates(runbooks) ++ links
  end

  defp parse(path, content) do
    case String.split(content, ~r/\r?\n/, parts: 2) do
      ["---", rest] ->
        case String.split(rest, ~r/^---[ \t]*$/m, parts: 2) do
          [yaml, body] -> front_matter(path, yaml, body, line_count(yaml) + 1)
          _ -> {:error, [violation(path, 1, "front-matter", "front matter is not closed by ---")]}
        end

      _ ->
        {:error, [violation(path, 1, "front-matter", "a runbook starts with a --- front matter")]}
    end
  end

  defp front_matter(path, yaml, body, body_line) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{} = meta} ->
        {:ok, %{path: path, meta: meta, body: body, body_line: body_line}}

      _ ->
        {:error, [violation(path, 1, "front-matter", "front matter is not a YAML mapping")]}
    end
  end

  defp line_count(text), do: length(String.split(text, "\n"))

  defp check(%{path: path, meta: meta} = runbook, today) do
    kind = meta["kind"]
    required = if kind == "incident", do: @common, else: @common ++ @runbook_fields
    missing = for field <- required, blank?(meta[field]), do: field

    missing_violations =
      for field <- missing,
          do: violation(path, 1, "front-matter", "missing front matter field `#{field}`")

    present = Map.drop(meta, missing)

    fields = Enum.flat_map(present, &field(path, &1, kind, today))
    missing_violations ++ fields ++ sections(runbook) ++ blocks(runbook)
  end

  defp field(path, {"id", id}, _kind, _today) do
    if id == Path.basename(path, ".md"),
      do: [],
      else: [invalid(path, "id", "`id` is the file name without .md")]
  end

  defp field(path, {"kind", kind}, _kind, _today),
    do: one_of(path, "kind", kind, @kinds)

  defp field(path, {"severity", severity}, _kind, _today),
    do: one_of(path, "severity", severity, @severities)

  defp field(path, {"tenant_scope", scope}, _kind, _today),
    do: one_of(path, "tenant_scope", scope, @tenant_scopes)

  defp field(path, {"tested_by", tested_by}, _kind, _today),
    do: one_of(path, "tested_by", tested_by, @tested_by)

  defp field(path, {"channels", channels}, _kind, _today) do
    if is_list(channels) and channels != [] and Enum.all?(channels, &(&1 in @channels)),
      do: [],
      else: [invalid(path, "channels", "`channels` is a list of #{Enum.join(@channels, ", ")}")]
  end

  defp field(path, {"alerts", alerts}, kind, _today) do
    cond do
      not (is_list(alerts) and Enum.all?(alerts, &is_binary/1)) ->
        [invalid(path, "alerts", "`alerts` is a list of alert names")]

      kind == "alert" and alerts == [] ->
        [invalid(path, "alerts", "an alert runbook lists its alerts")]

      kind in ["procedure", "incident"] and alerts != [] ->
        [invalid(path, "alerts", "a #{kind} lists no alerts; set kind: alert")]

      true ->
        []
    end
  end

  defp field(path, {"automation", level}, _kind, _today) do
    if level in 1..4,
      do: [],
      else: [invalid(path, "automation", "`automation` is 1, 2, 3 or 4 (0 is not accepted)")]
  end

  defp field(path, {"eta_minutes", eta}, _kind, _today) do
    if is_integer(eta) and eta > 0,
      do: [],
      else: [invalid(path, "eta_minutes", "`eta_minutes` is a positive integer")]
  end

  defp field(path, {"reversible", reversible}, _kind, _today) do
    if is_boolean(reversible),
      do: [],
      else: [invalid(path, "reversible", "`reversible` is true or false")]
  end

  defp field(path, {"last_tested", value}, _kind, today) do
    case date(value) do
      {:ok, date} ->
        age = Date.diff(today, date)

        cond do
          age < 0 ->
            [invalid(path, "last_tested", "`last_tested` is in the future")]

          age > @max_age_days ->
            [violation(path, 1, "stale", stale_message(age))]

          true ->
            []
        end

      :error ->
        [invalid(path, "last_tested", "`last_tested` is a date (YYYY-MM-DD)")]
    end
  end

  defp field(_path, _field, _kind, _today), do: []

  defp stale_message(age),
    do: "last tested #{age} days ago; a runbook older than #{@max_age_days} days is unreliable"

  defp date(%Date{} = date), do: {:ok, date}

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp date(_value), do: :error

  defp one_of(path, name, value, allowed) do
    if value in allowed,
      do: [],
      else: [invalid(path, name, "`#{name}` is one of #{Enum.join(allowed, ", ")}")]
  end

  defp invalid(path, _name, message), do: violation(path, 1, "front-matter", message)

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp lines(%{body: body, body_line: first}) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(first)
  end

  defp outside_fences(lines) do
    {result, _open} =
      Enum.map_reduce(lines, false, fn {text, no}, open ->
        if String.starts_with?(text, "```"),
          do: {{text, no, :fence}, not open},
          else: {{text, no, if(open, do: :code, else: :prose)}, open}
      end)

    result
  end

  defp sections(%{path: path, meta: meta} = runbook) do
    marked = runbook |> lines() |> outside_fences()

    {headings, bodies} =
      Enum.reduce(marked, {[], %{}}, fn
        {"## " <> heading, no, :prose}, {headings, bodies} ->
          {[{String.trim(heading), no} | headings], bodies}

        {text, _no, kind}, {[{heading, no} | _] = headings, bodies} ->
          content? = kind != :prose or String.trim(text) != ""
          {headings, Map.update(bodies, {heading, no}, content?, &(&1 or content?))}

        _line, acc ->
          acc
      end)

    headings = Enum.reverse(headings)

    empty =
      for {heading, no} = key <- headings, not Map.get(bodies, key, false) do
        violation(path, no, "section", "section `#{heading}` is empty; write Unknown. if so")
      end

    order =
      if meta["kind"] != "incident" and Enum.map(headings, &elem(&1, 0)) != @sections do
        [
          violation(
            path,
            runbook.body_line,
            "section",
            "the sections are #{Enum.join(@sections, ", ")}, in this order"
          )
        ]
      else
        []
      end

    order ++ empty
  end

  defp blocks(%{path: path} = runbook) do
    {violations, open} =
      runbook
      |> lines()
      |> Enum.reduce({[], nil}, fn {text, no}, {violations, open} ->
        fence = String.starts_with?(text, "```")

        case {open, fence} do
          {nil, true} ->
            info = text |> String.trim_leading("`") |> String.trim()
            {violations, {no, info, []}}

          {{start, info, body}, true} ->
            {block(path, start, info, Enum.reverse(body)) ++ violations, nil}

          {{start, info, body}, false} ->
            {violations, {start, info, [text | body]}}

          {nil, false} ->
            {violations, nil}
        end
      end)

    case open do
      nil -> violations
      {start, _info, _body} -> [violation(path, start, "fence", "code block is not closed")]
    end
  end

  defp block(path, start, info, body) do
    if String.split(info) == ["sh", "state-changing"] do
      commands =
        body
        |> Enum.join("\n")
        |> String.replace(~r/\\\n/, " ")
        |> String.split("\n")
        |> Enum.reject(&(String.trim(&1) == ""))

      if length(commands) == 1 and not chained?(hd(commands)),
        do: [],
        else: [
          violation(path, start, "state-changing", "a state-changing block holds one command")
        ]
    else
      []
    end
  end

  defp chained?(command), do: chained?(String.graphemes(command), nil)

  defp chained?([], _open), do: false
  defp chained?(["\\", _ | rest], open), do: chained?(rest, open)
  defp chained?([q | rest], nil) when q in ["'", "\""], do: chained?(rest, q)
  defp chained?([q | rest], q), do: chained?(rest, nil)
  defp chained?([";" | _rest], nil), do: true
  defp chained?(["&", "&" | _rest], nil), do: true
  defp chained?(["|", "|" | _rest], nil), do: true
  defp chained?([_ | rest], open), do: chained?(rest, open)

  defp alerts(root) do
    case YamlElixir.read_from_file(Path.join(root, @alerts)) do
      {:ok, %{"groups" => groups}} when is_list(groups) ->
        rules = for %{"rules" => rules} <- groups, %{"alert" => _} = rule <- rules, do: rule
        Enum.reduce(rules, {%{}, []}, &pointer/2)

      _ ->
        {%{}, [violation(@alerts, 0, "alerts", "alert rules cannot be read")]}
    end
  end

  defp pointer(%{"alert" => name} = rule, {pointers, violations}) do
    case target(get_in(rule, ["annotations", "runbook_url"])) do
      {:ok, file} ->
        {Map.update(pointers, file, [name], &[name | &1]), violations}

      :missing ->
        message = "alert #{name} has no runbook_url"
        {pointers, [violation(@alerts, 0, "runbook_url", message) | violations]}

      :invalid ->
        message = "alert #{name}: runbook_url is runbooks/<id>.md"
        {pointers, [violation(@alerts, 0, "runbook_url", message) | violations]}
    end
  end

  defp target(nil), do: :missing

  defp target(url) when is_binary(url) do
    path = String.replace_prefix(url, @url_prefix, "")

    if Regex.match?(~r{\Arunbooks/[a-z0-9][a-z0-9-]*\.md\z}, path),
      do: {:ok, path},
      else: :invalid
  end

  defp target(_url), do: :invalid

  defp duplicates(runbooks) do
    runbooks
    |> Enum.group_by(& &1.meta["id"])
    |> Enum.flat_map(fn
      {nil, _} ->
        []

      {_id, [_]} ->
        []

      {id, [_ | dups]} ->
        for %{path: path} <- dups, do: violation(path, 1, "front-matter", "duplicate id #{id}")
    end)
  end

  defp links(root, runbooks, pointers) do
    by_path = Map.new(runbooks, &{&1.path, &1})

    dangling =
      for {file, names} <- pointers,
          not File.regular?(Path.join(root, file)),
          name <- names do
        violation(@alerts, 0, "runbook_url", "alert #{name} points at missing #{file}")
      end

    wrong_kind =
      for {file, names} <- pointers,
          %{meta: meta} <- [by_path[file]],
          meta["kind"] != "alert" do
        violation(file, 1, "kind", "alerts #{Enum.join(names, ", ")} point here; set kind: alert")
      end

    unreferenced =
      for %{meta: %{"kind" => "alert"}} = runbook <- runbooks,
          message <- [mismatch(runbook, Map.get(pointers, runbook.path, []))],
          is_binary(message),
          do: violation(runbook.path, 1, "alerts", message)

    dangling ++ wrong_kind ++ unreferenced
  end

  defp mismatch(_runbook, []),
    do: "no alert points here; point an alert at it or set kind: procedure"

  defp mismatch(%{meta: meta}, pointing) do
    listed = if is_list(meta["alerts"]), do: Enum.sort(meta["alerts"]), else: []
    pointing = Enum.sort(pointing)

    if listed == pointing,
      do: nil,
      else: "front matter alerts #{inspect(listed)} differ from #{inspect(pointing)}"
  end

  defp violation(path, line, rule, message),
    do: %Violation{path: path, line: line, rule: rule, message: message}
end
