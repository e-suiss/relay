defmodule RelayDev.Fixture do
  @moduledoc "Writes small file trees for lint tests."

  @doc "Writes `files` (path => content) under `root`."
  @spec write!(Path.t(), %{String.t() => iodata()}) :: :ok
  def write!(root, files) do
    for {path, content} <- files do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    :ok
  end

  @doc "Returns the rules of violations."
  @spec rules([RelayDev.Lint.Violation.t()]) :: [String.t()]
  def rules(violations), do: Enum.map(violations, & &1.rule)
end
