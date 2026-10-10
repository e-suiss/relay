defmodule RelayDev.Lint.Comments do
  @moduledoc """
  Comment lint. Code and configuration carry no explanatory comments: only bare spec ID lines, shebangs, tool directives, `TODO(#n):`, GitHub Actions version notes and, in Rust, `// SAFETY:`, `///` and `//!`. The reason behind code lives in the specification.
  """

  alias RelayDev.Lint
  alias RelayDev.Lint.Violation

  @families ~w(MD F L MKT C INV E X API WF TP CH PC DS IN WH AG TN T OP OQ)
  @id "(?:Access\\s+)?(?:#{Enum.join(@families, "|")})-\\d+(?:\\s*\\(\\d+(?:,\\s*\\d+)*\\))?"
  @id_line Regex.compile!("^#{@id}(?:[,\\s]+#{@id})*$")
  @directive ~r/^(credo:|sobelow_skip|coveralls-ignore|yaml-language-server:|syntax=|escape=|check=|shellcheck\s|claims-allow|dialyzer)/
  @todo ~r/^TODO\(#\d+\):\s+\S/
  @action_note ~r/^v?\d+(\.\d+)*$/

  @elixir_globs [
    "{lib,lib_dev,test,config,bench,credo,priv,rel}/**/*.{ex,exs}",
    "*.exs",
    ".credo.exs"
  ]
  @hash_globs [
    "**/*.{yml,yaml,toml,sh,eex}",
    "**/Dockerfile*",
    "justfile",
    ".github/CODEOWNERS",
    ".tool-versions",
    "**/.gitignore",
    "**/.npmrc"
  ]
  @rust_globs ["native/**/*.rs"]

  # T-73
  @doc "Returns comment violations under `root`."
  @spec run(Path.t()) :: [Violation.t()]
  def run(root) do
    elixir = Lint.files(root, @elixir_globs)
    hash = Lint.files(root, @hash_globs) -- elixir
    rust = Lint.files(root, @rust_globs)

    Enum.flat_map(elixir, &elixir_file(root, &1)) ++
      Enum.flat_map(hash, &hash_file(root, &1)) ++ Enum.flat_map(rust, &rust_file(root, &1))
  end

  @doc "Returns true if the text after `#` is an allowed comment."
  @spec allowed?(String.t(), keyword()) :: boolean()
  def allowed?(text, opts \\ []) do
    text = String.trim(text)

    Regex.match?(@id_line, text) or Regex.match?(@directive, text) or Regex.match?(@todo, text) or
      (Keyword.get(opts, :action_note, false) and Regex.match?(@action_note, text))
  end

  defp elixir_file(root, path) do
    source = File.read!(Path.join(root, path))

    case Code.string_to_quoted_with_comments(source, file: path, emit_warnings: false) do
      {:ok, _ast, comments} ->
        for %{line: line, text: "#" <> text} <- comments,
            not (line == 1 and String.starts_with?(text, "!")),
            not allowed?(text),
            do: violation(path, line)

      {:error, _} ->
        [%Violation{path: path, line: 0, rule: "comment", message: "file does not parse"}]
    end
  end

  defp hash_file(root, path) do
    root
    |> Path.join(path)
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({false, []}, fn {line, no}, {in_string?, acc} ->
      toggles = rem(length(Regex.scan(~r/"""|'''/, line)), 2) == 1
      found = if in_string?, do: [], else: hash_line(path, line, no)
      {if(toggles, do: not in_string?, else: in_string?), acc ++ found}
    end)
    |> elem(1)
  end

  defp hash_line(path, line, no) do
    trimmed = String.trim_leading(line)

    cond do
      String.starts_with?(trimmed, "#!/") ->
        []

      String.starts_with?(trimmed, "#") ->
        if allowed?(String.trim_leading(trimmed, "#")), do: [], else: [violation(path, no)]

      true ->
        trailing(path, line, no)
    end
  end

  defp trailing(path, line, no) do
    case Regex.run(~r/^(.*?\S)\s+#\s?(.*)$/, line) do
      [_, code, text] ->
        cond do
          quoted?(code) -> []
          allowed?(text, action_note: String.contains?(code, "uses:")) -> []
          true -> [violation(path, no)]
        end

      nil ->
        []
    end
  end

  defp quoted?(code) do
    rem(length(String.split(code, "\"")) - 1, 2) == 1 or
      rem(length(String.split(code, "'")) - 1, 2) == 1
  end

  defp rust_file(root, path) do
    root
    |> Path.join(path)
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, no} -> rust_line(path, line, no) end)
  end

  defp rust_line(path, line, no) do
    case Regex.run(~r{//(.*)$}, line) do
      [_, "/" <> _] -> []
      [_, "!" <> _] -> []
      [_, " SAFETY:" <> _] -> []
      [_, text] -> if allowed?(text), do: [], else: [violation(path, no)]
      nil -> []
    end
  end

  defp violation(path, line),
    do: %Violation{
      path: path,
      line: line,
      rule: "comment",
      message: "explanatory comment; the reason belongs in the spec (T-73)"
    }
end
