defmodule Relay.Templates.Sanitizer do
  @moduledoc """
  The common change log of content cleanups (INV-1). Every cleanup that changes rendered content (invalid UTF-8, the SMS, push, e-mail and WhatsApp sanitizers, transliteration) returns `{value, changes}`; no cleanup changes content without a change entry, and a decision to keep flagged content is recorded too.

  A change is `%{rule: atom, action: :removed | :replaced | :truncated | :flagged | :added, field: String.t() | nil, count: non_neg_integer, detail: map}`. `count` is the number of affected code points (bytes for `:invalid_utf8`, graphemes for truncation), `field` the variant field the change applies to and `detail` carries code points and limits, never content.
  """

  @type action :: :removed | :replaced | :truncated | :flagged | :added
  @type change :: %{
          rule: atom(),
          action: action(),
          field: String.t() | nil,
          count: non_neg_integer(),
          detail: map()
        }
  @type result :: {String.t(), [change()]}
  @type predicate :: (non_neg_integer() -> boolean())

  # INV-1
  @doc "Builds one change entry."
  @spec change(atom(), action(), non_neg_integer(), keyword()) :: change()
  def change(rule, action, count, opts \\ []) do
    %{
      rule: rule,
      action: action,
      field: Keyword.get(opts, :field),
      count: count,
      detail: Keyword.get(opts, :detail, %{})
    }
  end

  # INV-1
  # TP-20
  @doc "Removes invalid UTF-8 byte sequences; the change counts the removed bytes."
  @spec utf8(binary(), String.t() | nil) :: result()
  def utf8(value, field \\ nil) when is_binary(value) do
    if String.valid?(value) do
      {value, []}
    else
      {clean, bytes} = strip_invalid(value, [], 0)
      {clean, [change(:invalid_utf8, :removed, bytes, field: field)]}
    end
  end

  # INV-1
  @doc "Removes every code point of a valid UTF-8 string for which `drop?` is true and records the count under `rule`."
  @spec drop(String.t(), atom(), String.t() | nil, predicate()) :: result()
  def drop(value, rule, field, drop?) do
    {kept, removed} =
      for <<c::utf8 <- value>>, reduce: {[], []} do
        {kept, removed} ->
          if drop?.(c), do: {kept, [c | removed]}, else: {[c | kept], removed}
      end

    case removed do
      [] ->
        {value, []}

      _ ->
        detail = %{codepoints: removed |> Enum.uniq() |> Enum.sort()}
        entry = change(rule, :removed, length(removed), field: field, detail: detail)
        {kept |> Enum.reverse() |> List.to_string(), [entry]}
    end
  end

  # INV-1
  @doc "Runs cleanup steps in order, each a function from a value to `{value, changes}`, and concatenates their changes."
  @spec pipe(String.t(), [(String.t() -> result())]) :: result()
  def pipe(value, steps) do
    Enum.reduce(steps, {value, []}, fn step, {current, changes} ->
      {next, more} = step.(current)
      {next, changes ++ more}
    end)
  end

  # INV-1
  @doc "Sets `field` on every change that has none."
  @spec with_field([change()], String.t()) :: [change()]
  def with_field(changes, field),
    do: Enum.map(changes, fn change -> %{change | field: change.field || field} end)

  defp strip_invalid(<<c::utf8, rest::binary>>, acc, bytes),
    do: strip_invalid(rest, [acc, <<c::utf8>>], bytes)

  defp strip_invalid(<<_byte, rest::binary>>, acc, bytes), do: strip_invalid(rest, acc, bytes + 1)

  defp strip_invalid(<<>>, acc, bytes), do: {IO.iodata_to_binary(acc), bytes}
end
