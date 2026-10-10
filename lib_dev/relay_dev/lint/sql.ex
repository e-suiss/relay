defmodule RelayDev.Lint.Sql do
  @moduledoc """
  SQL lint. Rejects physical deletes (`DELETE`, `TRUNCATE`, data `DROP`, Ecto deletes and column removal) and `AT TIME ZONE` in migrations and application code. Exceptions live in `conformance/catalog/sql-allow.json` with a reason.
  """

  alias RelayDev.Lint

  @allowlist "conformance/catalog/sql-allow.json"
  @globs ["priv/repo/migrations/**/*.{exs,sql}", "lib/**/*.{ex,sql}"]

  @patterns [
    {"physical_delete", ~r/\bDELETE\s+FROM\b/i, "physical DELETE is forbidden (INV-47, OP-9)"},
    {"physical_delete", ~r/\bTRUNCATE\b/i, "TRUNCATE is forbidden (INV-47, OP-9)"},
    {"physical_delete", ~r/\bDROP\s+(TABLE|SCHEMA|DATABASE|COLUMN|MATERIALIZED\s+VIEW|OWNED)\b/i,
     "dropping data is forbidden (INV-47, OP-9)"},
    {"physical_delete", ~r/\bdrop(_if_exists)?[\s(]+table\(/,
     "dropping a table is forbidden (INV-47, OP-9)"},
    {"physical_delete", ~r/^\s*remove[\s(]+:/, "removing a column is forbidden (INV-47, OP-9)"},
    {"physical_delete", ~r/\bRepo\.delete(_all)?!?\b/, "Repo.delete is forbidden (INV-47, OP-9)"},
    {"physical_delete", ~r/\bMulti\.delete(_all)?\b/,
     "Ecto.Multi.delete is forbidden (INV-47, OP-9)"},
    {"at_time_zone", ~r/\bAT\s+TIME\s+ZONE\b/i,
     "time zone conversion in SQL is forbidden (WF-47, TP-43)"}
  ]

  # T-69
  # INV-47
  # WF-47
  @doc "Returns SQL violations under `root`."
  @spec run(Path.t()) :: [Lint.Violation.t()]
  def run(root) do
    {allowed, invalid} = Lint.allowlist(root, @allowlist)

    found =
      for path <- Lint.files(root, @globs),
          violation <- Lint.scan_lines(path, File.read!(Path.join(root, path)), @patterns),
          not Lint.allowed?(allowed, violation),
          do: violation

    invalid ++ found
  end
end
