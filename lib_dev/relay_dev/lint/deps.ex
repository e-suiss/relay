defmodule RelayDev.Lint.Deps do
  @moduledoc """
  Dependency lint. Every Hex dependency in `mix.lock` carries a permissive license, and frameworks excluded from the core are absent.
  """

  alias RelayDev.Lint.Violation

  @permissive [
    "MIT",
    "Apache-2.0",
    "Apache 2.0",
    "BSD-2-Clause",
    "BSD 2-Clause",
    "BSD-3-Clause",
    "BSD 3-Clause",
    "ISC",
    "0BSD",
    "Zlib",
    "CC0-1.0",
    "Unlicense"
  ]
  @forbidden ~w(ash commanded eventstore commanded_eventstore_adapter)

  # T-51
  # T-62
  @doc "Returns dependency violations for a project at `root` whose dependencies are fetched."
  @spec run(Path.t()) :: [Violation.t()]
  def run(root) do
    lock = lock(root)

    Enum.flat_map(lock, fn {name, entry} ->
      forbidden(name) ++ license(root, name, entry)
    end)
  end

  defp lock(root) do
    path = Path.join(root, "mix.lock")

    if File.exists?(path), do: Mix.Dep.Lock.read(path), else: %{}
  end

  defp forbidden(name) do
    if Atom.to_string(name) in @forbidden,
      do: [
        %Violation{
          path: "mix.lock",
          line: 0,
          rule: "forbidden_framework",
          message: "#{name} is excluded from the core (T-51)"
        }
      ],
      else: []
  end

  defp license(root, name, entry) when elem(entry, 0) == :hex do
    metadata = Path.join([root, "deps", Atom.to_string(name), "hex_metadata.config"])

    licenses =
      case :file.consult(String.to_charlist(metadata)) do
        {:ok, terms} ->
          terms |> List.keyfind("licenses", 0, {"licenses", []}) |> elem(1) |> List.wrap()

        {:error, _} ->
          :unknown
      end

    cond do
      licenses == :unknown ->
        [
          %Violation{
            path: "mix.lock",
            line: 0,
            rule: "license",
            message: "#{name}: dependencies not fetched"
          }
        ]

      licenses != [] and Enum.all?(licenses, &(&1 in @permissive)) ->
        []

      true ->
        [
          %Violation{
            path: "mix.lock",
            line: 0,
            rule: "license",
            message: "#{name}: non-permissive or missing license #{inspect(licenses)}"
          }
        ]
    end
  end

  defp license(_root, name, _entry),
    do: [
      %Violation{
        path: "mix.lock",
        line: 0,
        rule: "source",
        message: "#{name}: only Hex packages are allowed"
      }
    ]
end
