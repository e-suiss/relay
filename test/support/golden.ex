defmodule Relay.Golden do
  @moduledoc """
  Golden-file assertions. A golden file holds the expected output of a provider request, a render or a signature; an unexpected difference fails the test and blocks the dependency upgrade that caused it. Set `GOLDEN_UPDATE` only when the difference is intended.
  """

  import ExUnit.Assertions

  @root Path.expand("../golden", __DIR__)

  # T-50
  @doc "Asserts that `actual` equals the golden file `name`."
  @spec assert_golden(String.t(), iodata()) :: true
  def assert_golden(name, actual) do
    path = Path.join(@root, name)
    actual = IO.iodata_to_binary(actual)

    if update?() do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, actual)
    end

    case File.read(path) do
      {:ok, expected} -> assert actual == expected, "golden file #{name} differs"
      {:error, :enoent} -> flunk("golden file #{name} is missing")
    end
  end

  defp update?, do: System.get_env("GOLDEN_UPDATE") == "1"
end
