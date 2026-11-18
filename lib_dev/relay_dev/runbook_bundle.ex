defmodule RelayDev.RunbookBundle do
  @moduledoc """
  Builds the offline copy of the runbooks: every Markdown file under `runbooks/` in one self-contained HTML page with a table of contents, no scripts and no external resources, so the on-call can open it when nothing of Relay answers. Links between runbooks become links inside the page.
  """

  @style """
  body{font:15px/1.5 system-ui,sans-serif;max-width:60rem;margin:0 auto;padding:1rem;color:#1b1f24;background:#fff}
  nav{border-bottom:1px solid #ccd;margin-bottom:2rem}
  article{border-top:2px solid #1b1f24;padding-top:1rem;margin-top:3rem}
  pre{background:#f3f4f6;padding:.75rem;overflow-x:auto;white-space:pre-wrap}
  code{font:13px/1.4 ui-monospace,monospace}
  table{border-collapse:collapse;margin:.5rem 0}
  td,th{border:1px solid #ccd;padding:.25rem .5rem;text-align:left;vertical-align:top}
  .meta td{font:13px ui-monospace,monospace}
  .state-changing{border-left:4px solid #b42318}
  @media (prefers-color-scheme:dark){body{color:#e6e8eb;background:#14161a}pre{background:#23262d}article{border-color:#e6e8eb}}
  """

  # OP-43 (7)
  # OP-48
  # OP-83
  @doc "Renders every runbook under `root` into one HTML document stamped with `label` (a version or commit)."
  @spec build(Path.t(), String.t()) :: String.t()
  def build(root, label) do
    docs =
      root
      |> RelayDev.Lint.files(["runbooks/**/*.md"])
      |> Enum.sort_by(&order/1)
      |> Enum.map(&document(root, &1))

    toc = Enum.map_join(docs, "\n", &toc_item/1)
    body = Enum.map_join(docs, "\n", & &1.html)

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Relay runbooks #{escape(label)}</title>
    <style>
    #{@style}</style>
    </head>
    <body>
    <nav><h1>Relay runbooks</h1><p>#{escape(label)}</p><ul>
    #{toc}
    </ul></nav>
    #{body}
    </body>
    </html>
    """
  end

  defp toc_item(doc), do: ~s(<li><a href="##{doc.anchor}">#{doc.title}</a></li>)

  defp order(path) do
    dir = Path.dirname(path)
    {dir != "runbooks", dir, Path.basename(path) != "README.md", path}
  end

  defp document(root, path) do
    content = File.read!(Path.join(root, path))
    {meta, body} = front_matter(content)
    lines = String.split(body, ~r/\r?\n/)
    anchor = anchor(path)

    title =
      Enum.find_value(lines, Path.basename(path, ".md"), fn
        "# " <> title -> String.trim(title)
        _ -> nil
      end)

    html = ~s(<article id="#{anchor}">\n#{meta}#{render(lines, Path.dirname(path))}</article>)
    %{anchor: anchor, title: inline(title, "runbooks"), html: html}
  end

  defp anchor(path) do
    path
    |> String.replace_prefix("runbooks/", "")
    |> String.replace_suffix(".md", "")
    |> String.replace(~r/[^A-Za-z0-9]+/, "-")
    |> String.downcase()
  end

  defp front_matter("---\n" <> rest) do
    case String.split(rest, ~r/^---[ \t]*$/m, parts: 2) do
      [yaml, body] ->
        rows =
          yaml
          |> String.split("\n", trim: true)
          |> Enum.map_join("\n", fn line ->
            [key, value] = line |> String.split(":", parts: 2) |> pad()
            "<tr><th>#{escape(key)}</th><td>#{escape(String.trim(value))}</td></tr>"
          end)

        {~s(<table class="meta">\n#{rows}\n</table>\n), body}

      _ ->
        {"", rest}
    end
  end

  defp front_matter(content), do: {"", content}

  defp pad([key]), do: [key, ""]
  defp pad([key, value]), do: [key, value]

  defp render(lines, dir), do: lines |> blocks([]) |> Enum.map_join("\n", &block(&1, dir))

  defp blocks([], acc), do: Enum.reverse(acc)

  defp blocks(["```" <> info | rest], acc) do
    {code, rest} = Enum.split_while(rest, &(not String.starts_with?(&1, "```")))
    blocks(Enum.drop(rest, 1), [{:code, String.trim(info), code} | acc])
  end

  defp blocks(["#" <> _ = line | rest], acc) do
    [hashes | text] = String.split(line, " ", parts: 2)
    blocks(rest, [{:heading, min(String.length(hashes), 6), Enum.join(text)} | acc])
  end

  defp blocks(["|" <> _ | _] = lines, acc) do
    {rows, rest} = Enum.split_while(lines, &String.starts_with?(&1, "|"))
    blocks(rest, [{:table, rows} | acc])
  end

  defp blocks([line | rest] = lines, acc) do
    cond do
      String.trim(line) == "" ->
        blocks(rest, acc)

      item?(line) ->
        {items, rest} = Enum.split_while(lines, &(item?(&1) or String.starts_with?(&1, "  ")))
        blocks(rest, [{:list, Regex.match?(~r/^\d/, line), items} | acc])

      true ->
        {text, rest} = Enum.split_while(lines, &paragraph?/1)
        blocks(rest, [{:paragraph, Enum.join(text, " ")} | acc])
    end
  end

  defp item?(line), do: Regex.match?(~r/^([-*]|\d+\.) /, line)

  defp paragraph?(line),
    do:
      String.trim(line) != "" and not item?(line) and
        not String.starts_with?(line, ["#", "|", "```"])

  defp block({:code, info, code}, _dir) do
    class = if String.contains?(info, "state-changing"), do: ~s( class="state-changing"), else: ""
    "<pre#{class}><code>#{escape(Enum.join(code, "\n"))}</code></pre>"
  end

  defp block({:heading, level, text}, dir), do: "<h#{level}>#{inline(text, dir)}</h#{level}>"

  defp block({:paragraph, text}, dir), do: "<p>#{inline(text, dir)}</p>"

  defp block({:list, ordered?, items}, dir) do
    tag = if ordered?, do: "ol", else: "ul"

    lis =
      items
      |> Enum.chunk_while([], &chunk_item/2, &flush_item/1)
      |> Enum.map_join("\n", fn item -> "<li>#{inline(item, dir)}</li>" end)

    "<#{tag}>\n#{lis}\n</#{tag}>"
  end

  defp block({:table, rows}, dir) do
    cells =
      rows
      |> Enum.reject(&Regex.match?(~r/^\|[\s:|-]+\|?\s*$/, &1))
      |> Enum.map(&cells/1)

    case cells do
      [head | body] ->
        header = Enum.map_join(head, "", &"<th>#{inline(&1, dir)}</th>")
        rows = Enum.map_join(body, "\n", &tr(&1, dir))
        "<table>\n<tr>#{header}</tr>\n#{rows}\n</table>"

      [] ->
        ""
    end
  end

  defp tr(cells, dir), do: "<tr>#{Enum.map_join(cells, "", &td(&1, dir))}</tr>"

  defp td(cell, dir), do: "<td>#{inline(cell, dir)}</td>"

  defp cells(row) do
    row
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp chunk_item(line, acc) do
    if item?(line) and acc != [],
      do: {:cont, Enum.join(Enum.reverse(acc), " "), [strip_marker(line)]},
      else: {:cont, [strip(line, acc) | acc]}
  end

  defp flush_item([]), do: {:cont, []}
  defp flush_item(acc), do: {:cont, Enum.join(Enum.reverse(acc), " "), []}

  defp strip(line, []), do: strip_marker(line)
  defp strip(line, _acc), do: String.trim(line)

  defp strip_marker(line) do
    line
    |> String.replace(~r/^([-*]|\d+\.) /, "")
    |> String.replace_prefix("[ ] ", "\u2610 ")
  end

  defp inline(text, dir) do
    ~r/\[([^\]]+)\]\(([^)\s]+)\)/
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(fn part ->
      case Regex.run(~r/^\[([^\]]+)\]\(([^)\s]+)\)$/, part) do
        [_, label, href] -> ~s(<a href="#{escape(link(href, dir))}">#{code_spans(label)}</a>)
        nil -> code_spans(part)
      end
    end)
  end

  defp code_spans(text) do
    ~r/`[^`]+`/
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(fn
      "`" <> _ = code -> "<code>#{escape(String.trim(code, "`"))}</code>"
      plain -> plain |> escape() |> String.replace(~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
    end)
  end

  defp link(href, dir) do
    cond do
      String.contains?(href, "://") or String.starts_with?(href, "#") ->
        href

      String.ends_with?(href, ".md") ->
        "#" <> anchor(resolve(dir, href))

      String.ends_with?(href, "/") ->
        "#" <> anchor(resolve(dir, href <> "README.md"))

      true ->
        href
    end
  end

  defp resolve(dir, href) do
    dir
    |> Path.join(href)
    |> Path.expand("/")
    |> String.trim_leading("/")
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
