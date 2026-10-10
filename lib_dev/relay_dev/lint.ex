defmodule RelayDev.Lint do
  @moduledoc "Shared helpers for repository lints: file discovery, allowlists and reporting."

  defmodule Violation do
    @moduledoc "One lint finding."
    @enforce_keys [:path, :line, :rule, :message]
    defstruct [:path, :line, :rule, :message, text: ""]

    @type t :: %__MODULE__{
            path: String.t(),
            line: non_neg_integer(),
            rule: String.t(),
            message: String.t(),
            text: String.t()
          }
  end

  @ignored_dirs ~w(_build deps node_modules .git .elixir_ls doc cover tmp priv/plts docs .claude)

  @doc "Lists files under `root` matching any glob, relative to `root`, skipping build and dependency directories."
  @spec files(Path.t(), [String.t()]) :: [String.t()]
  def files(root, globs) do
    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1), match_dot: true))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.reject(&ignored?/1)
    |> visible(root)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp visible(paths, root) do
    if git_root?(root) do
      {out, 0} =
        System.cmd("git", ["-C", root, "ls-files", "--cached", "--others", "--exclude-standard"])

      listed = out |> String.split("\n", trim: true) |> MapSet.new()
      Enum.filter(paths, &MapSet.member?(listed, &1))
    else
      paths
    end
  end

  defp git_root?(root) do
    case System.cmd("git", ["-C", root, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {top, 0} -> Path.expand(String.trim(top)) == Path.expand(root)
      _ -> false
    end
  end

  defp ignored?(path),
    do: Enum.any?(@ignored_dirs, &(path == &1 or String.starts_with?(path, &1 <> "/")))

  @doc "Reads a JSON file from `root`; returns `default` if it does not exist."
  @spec read_json(Path.t(), String.t(), term()) :: term()
  def read_json(root, path, default) do
    case File.read(Path.join(root, path)) do
      {:ok, content} -> Jason.decode!(content)
      {:error, :enoent} -> default
    end
  end

  @doc """
  Loads an allowlist: a JSON list of `{"path", "rule", "match", "reason"}` entries, where `match` is an optional substring of the offending line. Entries without a reason are returned as violations.
  """
  @spec allowlist(Path.t(), String.t()) ::
          {[{String.t(), String.t(), String.t() | nil}], [Violation.t()]}
  def allowlist(root, path) do
    entries = read_json(root, path, [])

    Enum.reduce(entries, {[], []}, fn entry, {allowed, invalid} ->
      case entry do
        %{"path" => p, "rule" => r, "reason" => reason} when is_binary(reason) and reason != "" ->
          {[{p, r, entry["match"]} | allowed], invalid}

        _ ->
          {allowed,
           [
             %Violation{
               path: path,
               line: 0,
               rule: "allowlist",
               message: "entry without a reason: #{inspect(entry)}"
             }
             | invalid
           ]}
      end
    end)
  end

  @doc "Returns true if an allowlist entry covers the violation."
  @spec allowed?([{String.t(), String.t(), String.t() | nil}], Violation.t()) :: boolean()
  def allowed?(allowlist, %Violation{} = v) do
    Enum.any?(allowlist, fn {path, rule, match} ->
      path == v.path and rule == v.rule and (is_nil(match) or String.contains?(v.text, match))
    end)
  end

  @doc "Scans `content` line by line with a list of `{rule, regex, message}` patterns."
  @spec scan_lines(String.t(), String.t(), [{String.t(), Regex.t(), String.t()}]) :: [
          Violation.t()
        ]
  def scan_lines(path, content, patterns) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, no} ->
      for {rule, regex, message} <- patterns, Regex.match?(regex, line) do
        %Violation{path: path, line: no, rule: rule, message: message, text: line}
      end
    end)
    |> Enum.uniq_by(&{&1.line, &1.rule})
  end

  @doc "Prints violations and raises if there are any."
  @spec report!(String.t(), [Violation.t()]) :: :ok
  def report!(name, []), do: Mix.shell().info("#{name}: ok")

  def report!(name, violations) do
    for v <- Enum.sort_by(violations, &{&1.path, &1.line}) do
      Mix.shell().error("#{v.path}:#{v.line}: [#{v.rule}] #{v.message}")
    end

    Mix.raise("#{name}: #{length(violations)} violation(s)")
  end

  @doc "Parses the common `--root` option."
  @spec root([String.t()]) :: Path.t()
  def root(args) do
    {opts, _} = OptionParser.parse!(args, strict: [root: :string])
    Keyword.get(opts, :root, File.cwd!())
  end
end
