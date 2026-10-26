defmodule Relay.Platform.Valkey.Script do
  @moduledoc """
  A Lua script of `priv/valkey/<name>.lua`. The source is read when the calling module compiles, so a release carries the reviewed text and its SHA1; the SHA1s are pinned in `test/golden/valkey_scripts.txt`. A script touches only `KEYS[1]`, reads time only through `redis.call('TIME')` and replies with an array of integers. Run it with `Relay.Platform.Valkey.eval/4`.

      @external_resource Relay.Platform.Valkey.Script.path("gcra")
      @gcra Relay.Platform.Valkey.Script.read!("gcra")
  """

  @enforce_keys [:name, :source, :sha]
  defstruct [:name, :source, :sha]

  @type t :: %__MODULE__{name: String.t(), source: String.t(), sha: String.t()}

  @dir Path.expand("../../../../priv/valkey", __DIR__)
  @name ~r/\A[a-z][a-z0-9_]{0,63}\z/

  # T-9
  @doc "Returns the source directory of the scripts."
  @spec dir() :: Path.t()
  def dir, do: @dir

  @doc "Returns the source path of the script `name`."
  @spec path(String.t()) :: Path.t()
  def path(name) do
    unless is_binary(name) and Regex.match?(@name, name),
      do: raise(ArgumentError, "invalid script name: #{inspect(name)}")

    Path.join(@dir, name <> ".lua")
  end

  # sobelow_skip ["Traversal.FileModule"]
  @doc "Reads the script `name` from its source path; raises if it is missing."
  @spec read!(String.t()) :: t()
  def read!(name), do: new(name, File.read!(path(name)))

  @doc "Builds a script from its name and source and computes its SHA1."
  @spec new(String.t(), String.t()) :: t()
  def new(name, source) when is_binary(name) and is_binary(source) do
    %__MODULE__{name: name, source: source, sha: sha(source)}
  end

  @doc "Returns the lowercase hexadecimal SHA1 that `SCRIPT LOAD` and `EVALSHA` use."
  @spec sha(String.t()) :: String.t()
  def sha(source) when is_binary(source),
    do: :sha |> :crypto.hash(source) |> Base.encode16(case: :lower)

  @doc "Lists every script under the source directory, sorted by name."
  @spec all() :: [t()]
  def all do
    @dir
    |> Path.join("*.lua")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&read!(Path.basename(&1, ".lua")))
  end
end
