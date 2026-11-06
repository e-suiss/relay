defmodule Relay.Config.Env do
  @moduledoc """
  Readers for environment variables used by `config/runtime.exs`. Every reader fails at startup when a value is missing or malformed; none supplies a default, except the trusted proxy list of `cidrs!/1`, which is empty when unset (E-91).
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

  # T-7
  # TN-26
  @doc "Returns a Valkey URL (`redis://` or `rediss://`); a password inside the URL is refused."
  @spec valkey_url!(String.t()) :: String.t()
  def valkey_url!(name) do
    url = fetch!(name)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["redis", "rediss"] and is_binary(host) and host != "" ->
        if is_binary(uri.userinfo) and String.contains?(uri.userinfo, ":"),
          do: raise(Error, "#{name} must not contain a password"),
          else: url

      _ ->
        raise Error, "#{name} must be a redis:// or rediss:// URL"
    end
  end

  # E-91
  @doc "Parses an optional comma-separated list of CIDR ranges (`10.0.0.0/8`, `2001:db8::/32` or a single address); unset or empty is the empty list, and a malformed range stops the node."
  @spec cidrs!(String.t()) :: [String.t()]
  def cidrs!(name) do
    name
    |> System.get_env("")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&cidr!(&1, name))
  end

  defp cidr!(range, name) do
    if cidr?(range), do: range, else: raise(Error, "#{name} names a malformed range: #{range}")
  end

  defp cidr?(range) do
    case String.split(range, "/", parts: 2) do
      [address] -> address(address) != nil
      [address, bits] -> prefix?(address(address), Integer.parse(bits))
    end
  end

  defp address(text) do
    case :inet.parse_strict_address(String.to_charlist(text)) do
      {:ok, ip} -> ip
      {:error, _reason} -> nil
    end
  end

  defp prefix?(ip, {bits, ""}) when tuple_size(ip) == 4, do: bits in 0..32
  defp prefix?(ip, {bits, ""}) when tuple_size(ip) == 8, do: bits in 0..128
  defp prefix?(_ip, _bits), do: false

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
