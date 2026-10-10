defmodule Relay.Config.Env do
  @moduledoc """
  Readers for environment variables used by `config/runtime.exs`. Every reader fails at startup when a value is missing or malformed; none supplies a default.
  """

  alias Relay.Config.Error

  # INV-46
  @doc "Returns the value of a required environment variable."
  @spec fetch!(String.t()) :: String.t()
  def fetch!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> raise Error, "environment variable #{name} is required"
    end
  end

  @doc "Returns a required environment variable parsed as a positive integer."
  @spec integer!(String.t()) :: pos_integer()
  def integer!(name) do
    value = fetch!(name)

    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> raise Error, "environment variable #{name} must be a positive integer"
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  @doc "Reads a secret from the file named by a required environment variable."
  @spec file!(String.t()) :: String.t()
  def file!(name) do
    path = fetch!(name)

    case File.read(path) do
      {:ok, content} ->
        String.trim_trailing(content, "\n")

      {:error, reason} ->
        raise Error, "cannot read file from #{name}: #{:file.format_error(reason)}"
    end
  end

  # TN-26
  @doc "Returns a database URL; a password inside the URL is refused."
  @spec database_url!(String.t()) :: String.t()
  def database_url!(name) do
    url = fetch!(name)

    case URI.parse(url) do
      %URI{userinfo: userinfo} when is_binary(userinfo) ->
        if String.contains?(userinfo, ":"),
          do: raise(Error, "#{name} must not contain a password; use DATABASE_PASSWORD_FILE"),
          else: url

      _ ->
        url
    end
  end

  # T-3
  @doc "Parses a required comma-separated role list."
  @spec roles!(String.t()) :: [Relay.Role.t()]
  def roles!(name) do
    known = Map.new(Relay.Role.all(), &{Atom.to_string(&1), &1})

    name
    |> fetch!()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn role ->
      Map.get(known, role) || raise(Error, "unknown role #{inspect(role)} in #{name}")
    end)
  end
end
