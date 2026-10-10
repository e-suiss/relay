defmodule RelayDev.Lint.Nif do
  @moduledoc """
  Native code lint. Every crate under `native/` is on the allowed list in `conformance/catalog/native.json`, as a NIF or as a Port program, with the rule that admitted it.
  """

  alias RelayDev.Lint
  alias RelayDev.Lint.Violation

  @catalog "conformance/catalog/native.json"

  # T-53
  # TN-63
  @doc "Returns native code violations under `root`."
  @spec run(Path.t()) :: [Violation.t()]
  def run(root) do
    catalog = Lint.read_json(root, @catalog, %{"nif" => [], "port" => []})
    nifs = names(catalog["nif"])
    ports = names(catalog["port"])

    crates =
      for path <- Lint.files(root, ["native/*/Cargo.toml"]) do
        content = File.read!(Path.join(root, path))
        [_, name] = Regex.run(~r/^name\s*=\s*"([^"]+)"/m, content)
        {path, name, content =~ ~r/^\s*rustler\s*=/m}
      end

    Enum.flat_map(crates, fn
      {path, name, true} ->
        if name in nifs,
          do: [],
          else: [violation(path, "NIF crate #{name} is not on the allowed list (T-53)")]

      {path, name, false} ->
        if name in ports or name in nifs,
          do: [],
          else: [violation(path, "native crate #{name} is not on the allowed list (T-53)")]
    end)
  end

  defp names(entries),
    do: for(%{"crate" => crate, "rule" => rule} <- entries || [], rule != "", do: crate)

  defp violation(path, message),
    do: %Violation{path: path, line: 0, rule: "native", message: message}
end
