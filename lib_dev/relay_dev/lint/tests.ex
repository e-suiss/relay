defmodule RelayDev.Lint.Tests do
  @moduledoc """
  Test discipline lint. A flaky test is never retried until green: it is quarantined with `@tag quarantine: "#<issue>"`, excluded from the suite, and blocks a release until it is fixed.
  """

  alias RelayDev.Lint

  @quarantine ~r/^\s*@(module|describe)?tag\s+(quarantine:|:quarantine\b)/
  @with_issue ~r/^\s*@(module|describe)?tag\s+quarantine:\s+"#\d+"/
  @retry ~r/^\s*@\w*tag\s+.*\b(retry|retries|max_retries|flaky)\s*:/

  # T-61
  @doc "Returns quarantine and retry violations under `root`; with `release: true` any quarantined test is a violation."
  @spec run(Path.t(), keyword()) :: [Lint.Violation.t()]
  def run(root, opts \\ []) do
    for path <- Lint.files(root, ["test/**/*.exs"]),
        violation <- scan(path, File.read!(Path.join(root, path)), opts),
        do: violation
  end

  defp scan(path, content, opts) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, no} ->
      cond do
        Regex.match?(@quarantine, line) and not Regex.match?(@with_issue, line) ->
          [
            violation(
              path,
              no,
              "quarantine",
              "a quarantined test names its issue: @tag quarantine: \"#123\""
            )
          ]

        Regex.match?(@quarantine, line) and Keyword.get(opts, :release, false) ->
          [violation(path, no, "quarantine", "a quarantined test blocks the release")]

        Regex.match?(@retry, line) ->
          [
            violation(
              path,
              no,
              "retry",
              "tests are never retried until green; quarantine instead"
            )
          ]

        true ->
          []
      end
    end)
  end

  defp violation(path, line, rule, message),
    do: %Lint.Violation{path: path, line: line, rule: rule, message: message}
end
