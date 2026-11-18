defmodule Relay.Templates.Convert.Expr do
  @moduledoc """
  The expression tree the template converters build and print as Relay Liquid (OP-96, OP-55 (9)): values (`{:var, root, accesses}`, `{:str, text}`, `{:num, text}`, `{:bool, value}`, `nil`, `{:special, name}`, `{:range, from, to}`), filter chains and conditions, and the output tokens of a converted template (`{:text, text}`, `{:verbatim, text}` inside a raw or comment block, `{:out, expression, trims}`, `{:tag, markup, trims}`). A variable path can be renamed through the alias table of an import.
  """

  @type value ::
          {:var, String.t(), [access()]}
          | {:str, String.t()}
          | {:num, String.t()}
          | {:bool, boolean()}
          | nil
          | {:special, String.t()}
          | {:range, value(), value()}
  @type access :: {:dot, String.t()} | {:index, value()}
  @type filter :: {String.t(), [value() | {String.t(), value()}]}
  @type expression :: {value(), [filter()]}
  @type condition :: [value() | {:op, String.t()} | {:join, String.t()}]
  @type trims :: {boolean(), boolean()}
  @type token ::
          {:text, String.t()}
          | {:verbatim, String.t()}
          | {:out, expression(), trims()}
          | {:tag, iodata(), trims()}

  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_-]*\??\z/

  # OP-96
  @doc "Whether a name prints as a Liquid identifier."
  @spec identifier?(String.t()) :: boolean()
  def identifier?(name) when is_binary(name), do: Regex.match?(@identifier, name)

  # OP-96
  @doc "Prints a value."
  @spec value(value()) :: iodata()
  def value({:var, root, accesses}), do: [root | Enum.map(accesses, &access/1)]
  def value({:str, text}), do: quote_string(text)
  def value({:num, text}), do: text
  def value({:bool, true}), do: "true"
  def value({:bool, false}), do: "false"
  def value(nil), do: "nil"
  def value({:special, name}), do: name
  def value({:range, from, to}), do: ["(", value(from), "..", value(to), ")"]

  defp access({:dot, name}) do
    if identifier?(name), do: [".", name], else: ["[", quote_string(name), "]"]
  end

  defp access({:index, value}), do: ["[", value(value), "]"]

  # OP-96
  @doc "Whether a string literal can be written in Liquid, which has no escapes: it may hold one kind of quote, not both."
  @spec printable_string?(String.t()) :: boolean()
  def printable_string?(text),
    do: not (String.contains?(text, "\"") and String.contains?(text, "'"))

  defp quote_string(text) do
    if String.contains?(text, "\""), do: ["'", text, "'"], else: ["\"", text, "\""]
  end

  # OP-96
  @doc "Prints an expression with its filters."
  @spec expression(expression()) :: iodata()
  def expression({value, filters}), do: [value(value) | Enum.map(filters, &filter/1)]

  defp filter({name, []}), do: [" | ", name]

  defp filter({name, args}),
    do: [" | ", name, ": ", Enum.intersperse(Enum.map(args, &argument/1), ", ")]

  defp argument({key, value}) when is_binary(key), do: [key, ": ", value(value)]
  defp argument(value), do: value(value)

  # OP-96
  @doc "Prints a condition: operands, comparison operators and `and`/`or`."
  @spec condition(condition()) :: iodata()
  def condition(parts) do
    parts
    |> Enum.map(fn
      {:op, op} -> op
      {:join, join} -> join
      operand -> value(operand)
    end)
    |> Enum.intersperse(" ")
  end

  # OP-96
  @doc "Prints the output tokens of a converted template as Relay Liquid source. Text that holds a Liquid delimiter is kept literal in a raw block."
  @spec render([token()]) :: String.t()
  def render(tokens), do: tokens |> Enum.map(&token/1) |> IO.iodata_to_binary()

  defp token({:text, text}) do
    if String.contains?(text, ["{{", "{%"]),
      do: ["{% raw %}", text, "{% endraw %}"],
      else: text
  end

  defp token({:verbatim, text}), do: text

  defp token({:out, expression, {left, right}}),
    do: [open("{{", left), " ", expression(expression), " ", close("}}", right)]

  defp token({:tag, markup, {left, right}}),
    do: [open("{%", left), " ", markup, " ", close("%}", right)]

  defp open(delimiter, true), do: delimiter <> "-"
  defp open(delimiter, false), do: delimiter

  defp close(delimiter, true), do: "-" <> delimiter
  defp close(delimiter, false), do: delimiter

  # OP-96
  @doc "Whether a text can be kept literal: a text that holds a Liquid delimiter is wrapped in a raw block, which cannot hold its own end tag."
  @spec literal_text?(String.t()) :: boolean()
  def literal_text?(text),
    do: not (String.contains?(text, ["{{", "{%"]) and String.contains?(text, "endraw"))

  # OP-96
  @doc "Renames the leading path of a variable through the alias table: an alias `old.name` with target `subscriber.first_name` turns `old.name.x` into `subscriber.first_name.x`. Answers the variable and the alias used, if any."
  @spec rename(value(), %{String.t() => String.t()}) :: {value(), String.t() | nil}
  def rename({:var, root, accesses} = var, aliases) when map_size(aliases) > 0 do
    {dots, rest} = Enum.split_while(accesses, &match?({:dot, _}, &1))
    path = [root | Enum.map(dots, fn {:dot, name} -> name end)]

    match =
      aliases
      |> Enum.map(fn {name, target} -> {String.split(name, "."), name, target} end)
      |> Enum.filter(fn {segments, _name, _target} -> prefix?(path, segments) end)
      |> Enum.max_by(fn {segments, _name, _target} -> length(segments) end, fn -> nil end)

    case match do
      nil ->
        {var, nil}

      {segments, name, target} ->
        [new_root | new_dots] = String.split(target, ".")
        tail = Enum.drop(path, length(segments))
        dots = Enum.map(new_dots ++ tail, &{:dot, &1})
        {{:var, new_root, dots ++ rest}, name}
    end
  end

  def rename(value, _aliases), do: {value, nil}

  defp prefix?(path, segments), do: Enum.take(path, length(segments)) == segments
end
