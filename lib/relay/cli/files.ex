defmodule Relay.CLI.Files do
  @moduledoc """
  File access of the command line tool. Every path comes from the person running it: the profile and secret files, data files and the definition files that `pull` writes and `push` reads.
  """

  # sobelow_skip ["Traversal.FileModule"]
  @doc "Reads a file."
  @spec read(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  def read(path), do: File.read(path)

  # sobelow_skip ["Traversal.FileModule"]
  @doc "Writes a file, creating its directory."
  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  def write(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, content)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  @doc "The files of a directory, sorted by name; none when it does not exist."
  @spec list(Path.t()) :: [Path.t()]
  def list(dir) do
    dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  # sobelow_skip ["Traversal.FileModule"]
  @doc "Whether a path is an existing regular file."
  @spec regular?(Path.t()) :: boolean()
  def regular?(path), do: File.regular?(path)

  @doc "A readable description of a file error."
  @spec describe(Path.t(), File.posix() | atom()) :: String.t()
  def describe(path, reason), do: "cannot use #{path}: #{:file.format_error(reason)}"
end
