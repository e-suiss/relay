defmodule Relay.Ingest.Pointer do
  @moduledoc """
  JSON Pointers (RFC 6901) over decoded JSON: reading a value and copying the values of an allow-list of pointers into a new document, the field allow-list that maps CloudEvents data without a transformation script (MD-16). The empty pointer is the whole document.
  """

  @type json :: term()

  @doc "Splits a pointer into its reference tokens; a pointer that does not start with `/` is invalid."
  @spec parse(String.t()) :: {:ok, [String.t()]} | :error
  def parse(""), do: {:ok, []}

  def parse("/" <> rest) do
    {:ok,
     rest
     |> String.split("/")
     |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))}
  end

  def parse(_pointer), do: :error

  # MD-16
  @doc "Reads the value at a pointer; `:error` when the pointer is invalid or names nothing."
  @spec get(json(), String.t()) :: {:ok, json()} | :error
  def get(document, pointer) do
    with {:ok, tokens} <- parse(pointer), do: walk(document, tokens)
  end

  defp walk(value, []), do: {:ok, value}

  defp walk(map, [token | rest]) when is_map(map) do
    case Map.fetch(map, token) do
      {:ok, value} -> walk(value, rest)
      :error -> :error
    end
  end

  defp walk(list, [token | rest]) when is_list(list) do
    case Integer.parse(token) do
      {index, ""} when index >= 0 and index < length(list) -> walk(Enum.at(list, index), rest)
      _ -> :error
    end
  end

  defp walk(_value, _tokens), do: :error

  # MD-16
  @doc "Copies the values at the allow-listed pointers into a new object at the same paths; pointers that name nothing are left out, and the empty pointer copies the whole document."
  @spec project(json(), [String.t()]) :: map()
  def project(document, pointers) do
    Enum.reduce(pointers, %{}, fn pointer, acc ->
      with {:ok, tokens} <- parse(pointer),
           {:ok, value} <- walk(document, tokens) do
        put(acc, tokens, value)
      else
        :error -> acc
      end
    end)
  end

  defp put(_acc, [], value) when is_map(value), do: value
  defp put(acc, [], _value), do: acc
  defp put(acc, [token], value) when is_map(acc), do: Map.put(acc, token, value)

  defp put(acc, [token | rest], value) when is_map(acc) do
    child =
      case Map.get(acc, token) do
        %{} = existing -> existing
        _ -> %{}
      end

    Map.put(acc, token, put(child, rest, value))
  end
end
