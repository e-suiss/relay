defmodule RelayDev.Credo.RepoOutsideStore do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: "SQL and `Repo` calls live only in each context's `*.Store` modules (T-58, T-60)."
    ]

  @message "Repo and SQL calls belong in a *.Store module (T-58, T-60)"

  @rules [
    {Relay.Repo, :_, @message},
    {Repo, :_, @message},
    {Ecto.Adapters.SQL, :_, @message}
  ]

  # T-60
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if store_file?(source_file.filename),
      do: [],
      else: RelayDev.Credo.Calls.issues(source_file, params, __MODULE__, @rules)
  end

  defp store_file?(path),
    do: Path.basename(path) == "store.ex" or String.ends_with?(path, "_store.ex")
end
