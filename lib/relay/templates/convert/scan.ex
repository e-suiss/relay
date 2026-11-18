defmodule Relay.Templates.Convert.Scan do
  @moduledoc """
  Delimiter scanning shared by the template converters (OP-96): the source is read character by character, a closing delimiter inside a quoted string does not close a tag, and line numbers are counted for findings. No regular expression takes part in the conversion.
  """

  # OP-96
  @doc "Splits `source` at the first closing `delimiter` that is not inside a quoted string: `{:ok, inside, rest}` or `:error` when it never closes."
  @spec close(String.t(), String.t()) :: {:ok, String.t(), String.t()} | :error
  def close(source, delimiter), do: close(source, delimiter, byte_size(delimiter), nil, 0)

  defp close(source, _delimiter, _size, _quote, at) when at >= byte_size(source), do: :error

  defp close(source, delimiter, size, quote, at) do
    char = :binary.at(source, at)
    left = byte_size(source) - at

    cond do
      quote == nil and left >= size and binary_part(source, at, size) == delimiter ->
        {:ok, binary_part(source, 0, at), binary_part(source, at + size, left - size)}

      quote == nil and char in [?", ?'] ->
        close(source, delimiter, size, char, at + 1)

      char == quote ->
        close(source, delimiter, size, nil, at + 1)

      true ->
        close(source, delimiter, size, quote, at + 1)
    end
  end

  # OP-96
  @doc "Splits `source` at the first `delimiter`, quoted or not, as a comment closes: `{:ok, inside, rest}` or `:error`."
  @spec close_plain(String.t(), String.t()) :: {:ok, String.t(), String.t()} | :error
  def close_plain(source, delimiter) do
    case :binary.match(source, delimiter) do
      {at, size} ->
        {:ok, binary_part(source, 0, at),
         binary_part(source, at + size, byte_size(source) - at - size)}

      :nomatch ->
        :error
    end
  end

  # OP-96
  @doc "The number of line breaks in a text."
  @spec lines(String.t()) :: non_neg_integer()
  def lines(text), do: length(:binary.matches(text, "\n"))

  # OP-96
  @doc "Strips one leading and one trailing whitespace control marker `marker` from a tag's inside and says which were there."
  @spec trims(String.t(), String.t()) :: {String.t(), {boolean(), boolean()}}
  def trims(inside, marker) do
    {left, inside} =
      if String.starts_with?(inside, marker),
        do: {true, binary_part(inside, 1, byte_size(inside) - 1)},
        else: {false, inside}

    {right, inside} =
      if inside != "" and String.ends_with?(inside, marker),
        do: {true, binary_part(inside, 0, byte_size(inside) - 1)},
        else: {false, inside}

    {String.trim(inside), {left, right}}
  end
end
