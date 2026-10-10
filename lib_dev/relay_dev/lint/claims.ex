defmodule RelayDev.Lint.Claims do
  @moduledoc """
  Claim language lint. Scans READMEs, documentation strings, API contracts and console texts for forbidden claims listed in `conformance/catalog/claims.json`. A line that quotes a forbidden claim on purpose carries the `claims-allow` marker.
  """

  alias RelayDev.Lint

  @denylist "conformance/catalog/claims.json"
  @globs [
    "*.md",
    ".github/**/*.{md,yml}",
    "lib/**/*.ex",
    "sdks/**/*.{md,yaml,yml,json,ts,tsx}",
    "web/**/*.{md,ts,tsx,json}",
    "conformance/**/*.md"
  ]

  # F-31
  # F-25
  # INV-60
  @doc "Returns claim violations under `root`."
  @spec run(Path.t()) :: [Lint.Violation.t()]
  def run(root) do
    patterns =
      for %{"id" => id, "rule" => rule, "pattern" => pattern, "message" => message} <-
            Lint.read_json(root, @denylist, []) do
        {"#{id} (#{rule})", Regex.compile!(pattern, "iu"), message}
      end

    for path <- Lint.files(root, @globs) -- [@denylist],
        violation <- Lint.scan_lines(path, File.read!(Path.join(root, path)), patterns),
        not allowed_line?(root, path, violation.line),
        do: violation
  end

  defp allowed_line?(root, path, line) do
    root
    |> Path.join(path)
    |> File.read!()
    |> String.split("\n")
    |> Enum.at(line - 1, "")
    |> String.contains?("claims-allow")
  end
end
