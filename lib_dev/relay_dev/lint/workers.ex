defmodule RelayDev.Lint.Workers do
  @moduledoc """
  Queue worker lint. Every queue worker in the application is built on the base worker `Relay.Worker`, which holds the one-hour job limit and the job rules; only the base worker itself uses `Oban.Worker` directly. `compiled/1` checks the same on compiled modules: every module with the `Oban.Worker` behaviour carries the base worker's `__relay_worker__/0` marker.
  """

  alias RelayDev.Lint

  @base "lib/relay/worker.ex"
  @message "queue workers use Relay.Worker (OP-69, INV-55)"
  @patterns [
    {"oban_worker", ~r/^\s*use\s+Oban\.(Pro\.)?Worker\b/, @message},
    {"oban_worker", ~r/^\s*@behaviour\s+Oban\.(Pro\.)?Worker\b/, @message}
  ]

  # OP-69 (5)
  # INV-55
  # T-15
  @doc "Returns workers under `root`'s `lib/` that do not use the base worker."
  @spec run(Path.t()) :: [Lint.Violation.t()]
  def run(root) do
    for path <- Lint.files(root, ["lib/**/*.ex"]),
        path != @base,
        violation <- Lint.scan_lines(path, File.read!(Path.join(root, path)), @patterns),
        do: violation
  end

  # OP-69 (5)
  @doc "Returns the compiled modules that implement `Oban.Worker` without the base worker's marker."
  @spec compiled([module()]) :: [module()]
  def compiled(modules) do
    for module <- modules,
        Code.ensure_loaded?(module),
        Oban.Worker in behaviours(module),
        not function_exported?(module, :__relay_worker__, 0),
        do: module
  end

  defp behaviours(module),
    do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
end
