defmodule Relay.CLI.Yaml do
  @moduledoc """
  YAML of the definition files. A value of the JSON data model is written in block style with its map keys in sorted order and every string double-quoted (characters YAML cannot print are escaped), so the same definition always gives the same bytes and every scalar keeps its JSON type when it is read back. A key is written plain only when it is a simple word that no YAML reader takes for a boolean or null.
  """

  @plain ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @unprintable ~r/[\x{7F}-\x{9F}\x{2028}\x{2029}\x{FEFF}\x{FFFE}\x{FFFF}]/u
  @reserved ~w(true false null yes no on off y n)

  # WF-59
  # X-33
  @doc "Writes a JSON value as a YAML document."
  @spec encode(term()) :: iolist()
  def encode(value), do: Enum.map(lines(value, 0), &[&1, ?\n])

  # WF-59
  # X-33
  @doc "Reads a YAML document into the JSON data model."
  @spec decode(binary()) :: {:ok, term()} | {:error, String.t()}
  def decode(content) when is_binary(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, "the file is not YAML: " <> Exception.message(error)}
    end
  rescue
    _exception -> {:error, "the file is not YAML"}
  end

  defp lines(map, indent) when is_map(map) and map_size(map) > 0 do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, value} -> entry(key(key), value, indent) end)
  end

  defp lines([_ | _] = list, indent), do: Enum.flat_map(list, &item(&1, indent))
  defp lines(value, indent), do: [[pad(indent), scalar(value)]]

  defp entry(key, value, indent) do
    if block?(value),
      do: [[pad(indent), key, ?:] | lines(value, indent + 2)],
      else: [[pad(indent), key, ": ", scalar(value)]]
  end

  defp item(value, indent) do
    if block?(value) do
      [[_pad | first] | rest] = lines(value, indent + 2)
      [[pad(indent), "- " | first] | rest]
    else
      [[pad(indent), "- ", scalar(value)]]
    end
  end

  defp block?(map) when is_map(map), do: map_size(map) > 0
  defp block?([_ | _]), do: true
  defp block?(_value), do: false

  defp key(key) when is_binary(key) do
    if Regex.match?(@plain, key) and String.downcase(key) not in @reserved,
      do: key,
      else: quoted(key)
  end

  defp scalar(nil), do: "null"
  defp scalar(true), do: "true"
  defp scalar(false), do: "false"
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar(value) when is_float(value), do: Jason.encode!(value)
  defp scalar(value) when is_binary(value), do: quoted(value)
  defp scalar(map) when is_map(map), do: "{}"
  defp scalar([]), do: "[]"

  defp quoted(text) do
    Regex.replace(@unprintable, Jason.encode!(text), fn char ->
      <<code::utf8>> = char
      "\\u" <> String.pad_leading(Integer.to_string(code, 16), 4, "0")
    end)
  end

  defp pad(0), do: ""
  defp pad(indent), do: :binary.copy(" ", indent)
end
