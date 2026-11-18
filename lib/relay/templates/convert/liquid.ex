defmodule Relay.Templates.Convert.Liquid do
  @moduledoc """
  Converts full Liquid (the Shopify dialect) to Relay's TP-45 subset (OP-96, OP-55 (9)). The source is split into text, outputs and tags by `Relay.Templates.Convert.Scan`, every output and tag markup is lexed and parsed into an expression tree (`Relay.Templates.Convert.Expr`) and the tree is printed again; blocks are matched on a stack. Tags and filters of the subset pass through; `echo` becomes an output, `liquid` its tags, an inline `#` comment a comment block, `remove` a `replace` with an empty string, and `escape` is dropped because Relay escapes every output for its channel. A `date` format that is not a Relay style is replaced by `medium` for review. `include` and `render` (partials), `cycle`, `tablerow`, `increment`, `decrement`, `for` with `reversed` or `offset: continue`, ranges, filters without a Relay equivalent and tags that call out over HTTP cannot be converted; nothing is guessed.
  """

  alias Relay.Templates.Convert.Expr
  alias Relay.Templates.Convert.Scan

  @type severity :: :info | :review | :cannot
  @type finding :: {severity(), String.t(), pos_integer() | nil, String.t()}
  @type result :: %{
          tokens: [Expr.token()],
          findings: [finding()],
          aliases: [String.t()],
          raw: boolean()
        }

  @same ~w(upcase downcase capitalize strip lstrip rstrip truncate replace prepend append default
           url_encode size first last join)
  @dropped ~w(escape escape_once)
  @styles ~w(short medium long full)
  @partials ~w(include render)
  @http ~w(connected_content http fetch request)
  @blocks %{
    "endif" => ["if"],
    "endunless" => ["unless"],
    "endcase" => ["case"],
    "endfor" => ["for"],
    "endcapture" => ["capture"]
  }
  @whitespace [" ", "\t", "\n", "\r"]

  # OP-96
  # OP-55 (9)
  @doc "Converts a Liquid source with the alias table `aliases` (old path to Relay path); answers the output tokens, the findings, the aliases used and whether a raw output was written."
  @spec convert(String.t(), %{String.t() => String.t()}) :: result()
  def convert(source, aliases) when is_binary(source) and is_map(aliases) do
    state = %{
      tokens: [],
      findings: [],
      stack: [],
      locals: MapSet.new(["forloop"]),
      aliases: aliases,
      used: MapSet.new(),
      raw: false
    }

    state = scan(source, 1, state)

    state =
      Enum.reduce(state.stack, state, fn {name, line}, acc ->
        finding(acc, :cannot, "syntax", line, "#{name} is never closed")
      end)

    %{
      tokens: Enum.reverse(state.tokens),
      findings: Enum.reverse(state.findings),
      aliases: state.used |> MapSet.to_list() |> Enum.sort(),
      raw: state.raw
    }
  end

  defp scan("", _line, state), do: state

  defp scan(source, line, state) do
    case :binary.match(source, ["{{", "{%"]) do
      :nomatch ->
        text(state, source)

      {at, 2} ->
        before = binary_part(source, 0, at)
        opener = binary_part(source, at, 2)
        rest = binary_part(source, at + 2, byte_size(source) - at - 2)
        delimited(opener, rest, line + Scan.lines(before), text(state, before))
    end
  end

  defp text(state, ""), do: state
  defp text(state, text), do: emit(state, {:text, text})

  defp delimited("{{", rest, line, state) do
    case Scan.close(rest, "}}") do
      {:ok, inside, rest} ->
        {markup, trims} = Scan.trims(inside, "-")
        scan(rest, line + Scan.lines(inside), output(state, markup, trims, line))

      :error ->
        finding(state, :cannot, "syntax", line, "an output is never closed")
    end
  end

  defp delimited("{%", rest, line, state) do
    case Scan.close(rest, "%}") do
      {:ok, inside, rest} ->
        {markup, trims} = Scan.trims(inside, "-")
        {name, args} = split_name(markup)
        next = line + Scan.lines(inside)
        {state, rest, next} = tag(name, args, trims, rest, line, next, state)
        scan(rest, next, state)

      :error ->
        finding(state, :cannot, "syntax", line, "a tag is never closed")
    end
  end

  defp split_name("#" <> rest), do: {"#", String.trim(rest)}

  defp split_name(markup) do
    case :binary.match(markup, @whitespace) do
      :nomatch ->
        {markup, ""}

      {at, _size} ->
        {binary_part(markup, 0, at),
         String.trim(binary_part(markup, at, byte_size(markup) - at))}
    end
  end

  defp tag(name, _args, trims, rest, line, next, state) when name in ["raw", "comment"] do
    case block_body(rest, "end" <> name, 0) do
      {:ok, body, end_trims, rest} ->
        state =
          state
          |> emit({:tag, name, trims})
          |> emit({:verbatim, body})
          |> emit({:tag, "end" <> name, end_trims})

        {state, rest, next + Scan.lines(body)}

      :error ->
        {finding(state, :cannot, "syntax", line, "#{name} is never closed"), "", next}
    end
  end

  defp tag("#", args, trims, rest, _line, next, state) do
    {comment(state, args, trims), rest, next}
  end

  defp tag(name, args, trims, rest, line, next, state),
    do: {statement(name, args, trims, line, state), rest, next}

  defp comment(state, text, trims) do
    state
    |> emit({:tag, "comment", trims})
    |> emit({:verbatim, text})
    |> emit({:tag, "endcomment", {false, false}})
  end

  defp block_body(source, end_name, from) do
    case :binary.match(source, "{%", scope: {from, byte_size(source) - from}) do
      :nomatch ->
        :error

      {at, 2} ->
        after_open = binary_part(source, at + 2, byte_size(source) - at - 2)

        with {:ok, inside, rest} <- Scan.close_plain(after_open, "%}"),
             {markup, trims} = Scan.trims(inside, "-"),
             {^end_name, _args} <- split_name(markup) do
          {:ok, binary_part(source, 0, at), trims, rest}
        else
          _other -> block_body(source, end_name, at + 2)
        end
    end
  end

  defp statement(name, args, trims, line, state) when name in ["if", "unless"] do
    case parse(args, &condition/1) do
      {:ok, parts} ->
        {state, parts} = map_condition(state, parts, line)
        state |> push(name, line) |> emit({:tag, [name, " ", Expr.condition(parts)], trims})

      :error ->
        syntax(state, name, line)
    end
  end

  defp statement("elsif", args, trims, line, state) do
    with true <- top?(state, ["if", "unless"]),
         {:ok, parts} <- parse(args, &condition/1) do
      {state, parts} = map_condition(state, parts, line)
      emit(state, {:tag, ["elsif ", Expr.condition(parts)], trims})
    else
      _other -> syntax(state, "elsif", line)
    end
  end

  defp statement("else", _args, trims, line, state) do
    if top?(state, ["if", "unless", "case", "for"]),
      do: emit(state, {:tag, "else", trims}),
      else: syntax(state, "else", line)
  end

  defp statement("case", args, trims, line, state) do
    case parse(args, &whole_value/1) do
      {:ok, value} ->
        {state, value} = map_value(state, value, line)
        state |> push("case", line) |> emit({:tag, ["case ", Expr.value(value)], trims})

      :error ->
        syntax(state, "case", line)
    end
  end

  defp statement("when", args, trims, line, state) do
    with true <- top?(state, ["case"]),
         {:ok, values} <- parse(args, &when_values/1) do
      {state, values} = map_values(state, values, line)
      markup = ["when ", Enum.intersperse(Enum.map(values, &Expr.value/1), ", ")]
      emit(state, {:tag, markup, trims})
    else
      _other -> syntax(state, "when", line)
    end
  end

  defp statement("for", args, trims, line, state) do
    case parse(args, &loop/1) do
      {:ok, {var, collection, params, flags}} ->
        {state, collection} = map_value(state, collection, line)
        {state, params} = map_params(state, params, line)
        state = Enum.reduce(flags, state, &loop_flag(&2, &1, line))
        markup = ["for ", var, " in ", Expr.value(collection), Enum.map(params, &param/1)]

        state
        |> push("for", line)
        |> local(var)
        |> emit({:tag, markup, trims})

      :error ->
        syntax(state, "for", line)
    end
  end

  defp statement(name, args, trims, line, state) when is_map_key(@blocks, name) do
    case state.stack do
      [{open, _line} | rest] ->
        if open in Map.fetch!(@blocks, name),
          do: emit(%{state | stack: rest}, {:tag, name, trims}),
          else: syntax(state, name, line)

      [] ->
        syntax(state, name, line)
    end
  end

  defp statement(name, "", trims, _line, state) when name in ["break", "continue"],
    do: emit(state, {:tag, name, trims})

  defp statement("assign", args, trims, line, state) do
    case parse(args, &assignment/1) do
      {:ok, {name, expression}} ->
        {state, expression} = map_expression(state, expression, line)
        markup = ["assign ", name, " = ", Expr.expression(expression)]
        state |> local(name) |> emit({:tag, markup, trims})

      :error ->
        syntax(state, "assign", line)
    end
  end

  defp statement("capture", args, trims, line, state) do
    case parse(args, &capture_name/1) do
      {:ok, name} ->
        state |> push("capture", line) |> local(name) |> emit({:tag, ["capture ", name], trims})

      :error ->
        syntax(state, "capture", line)
    end
  end

  defp statement("echo", args, trims, line, state), do: output(state, args, trims, line)

  defp statement("liquid", args, _trims, line, state) do
    args
    |> String.split("\n")
    |> Enum.with_index(line)
    |> Enum.reduce(state, fn {text, at}, acc ->
      case split_name(String.trim(text)) do
        {"", _args} -> acc
        {"#", _args} -> acc
        {"comment", _args} -> syntax(acc, "comment", at)
        {name, args} -> statement(name, args, {false, false}, at, acc)
      end
    end)
  end

  defp statement(name, _args, _trims, line, state) when name in @partials,
    do: finding(state, :cannot, "partial", line, "#{name} pulls in another template")

  defp statement(name, _args, _trims, line, state) when name in @http,
    do: finding(state, :cannot, "http_call", line, "#{name} calls out over HTTP")

  defp statement(name, _args, _trims, line, state),
    do: finding(state, :cannot, "tag_without_equivalent", line, "#{name} has no Relay equivalent")

  defp output(state, markup, trims, line) do
    case parse(markup, &expression/1) do
      {:ok, expression} ->
        {state, expression} = map_expression(state, expression, line)
        emit(state, {:out, expression, trims})

      :error ->
        finding(state, :cannot, "syntax", line, "an output cannot be read")
    end
  end

  defp loop_flag(state, :reversed, line),
    do: finding(state, :cannot, "for_reversed", line, "for with reversed has no equivalent")

  defp loop_flag(state, :continue, line),
    do: finding(state, :cannot, "for_offset_continue", line, "offset: continue has no equivalent")

  defp param({name, value}), do: [" ", name, ": ", Expr.value(value)]

  defp push(state, name, line), do: %{state | stack: [{name, line} | state.stack]}

  defp top?(%{stack: [{name, _line} | _rest]}, names), do: name in names
  defp top?(_state, _names), do: false

  defp local(state, name), do: %{state | locals: MapSet.put(state.locals, name)}

  defp emit(state, token), do: %{state | tokens: [token | state.tokens]}

  defp syntax(state, name, line),
    do: finding(state, :cannot, "syntax", line, "#{name} cannot be read")

  defp finding(state, severity, code, line, detail),
    do: %{state | findings: [{severity, code, line, detail} | state.findings]}

  defp map_expression(state, {value, filters}, line) do
    {state, value} = map_value(state, value, line)

    {state, filters} =
      Enum.reduce(filters, {state, []}, fn filter, {acc, mapped} ->
        {acc, more} = map_filter(acc, filter, line)
        {acc, mapped ++ more}
      end)

    {state, {value, filters}}
  end

  defp map_filter(state, {name, args}, line) when name in @same do
    {state, args} = map_arguments(state, args, line)
    {state, [{name, args}]}
  end

  defp map_filter(state, {"remove", [needle]}, line) do
    {state, [needle]} = map_arguments(state, [needle], line)
    {state, [{"replace", [needle, {:str, ""}]}]}
  end

  defp map_filter(state, {name, _args}, line) when name in @dropped,
    do: {finding(state, :info, "escape_dropped", line, "Relay escapes every output"), []}

  defp map_filter(state, {"date", [{:str, style}]}, _line) when style in @styles,
    do: {state, [{"date", [{:str, style}]}]}

  defp map_filter(state, {"date", args}, line) do
    detail = "the date format #{format_detail(args)} became the medium style"
    state = finding(state, :review, "date_format_replaced", line, detail)
    {state, [{"date", [{:str, "medium"}]}]}
  end

  defp map_filter(state, {name, args}, line) do
    detail = "the filter #{name} has no Relay equivalent"
    {finding(state, :cannot, "filter_without_equivalent", line, detail), [{name, args}]}
  end

  defp format_detail([{:str, format}]), do: format
  defp format_detail(_args), do: "given"

  defp map_arguments(state, args, line) do
    Enum.reduce(args, {state, []}, fn
      {key, value}, {acc, mapped} when is_binary(key) ->
        {acc, value} = map_value(acc, value, line)
        {acc, mapped ++ [{key, value}]}

      value, {acc, mapped} ->
        {acc, value} = map_value(acc, value, line)
        {acc, mapped ++ [value]}
    end)
  end

  defp map_params(state, params, line) do
    Enum.reduce(params, {state, []}, fn {name, value}, {acc, mapped} ->
      {acc, value} = map_value(acc, value, line)
      {acc, mapped ++ [{name, value}]}
    end)
  end

  defp map_values(state, values, line) do
    Enum.reduce(values, {state, []}, fn value, {acc, mapped} ->
      {acc, value} = map_value(acc, value, line)
      {acc, mapped ++ [value]}
    end)
  end

  defp map_condition(state, parts, line) do
    Enum.reduce(parts, {state, []}, fn
      {:op, "<>"}, {acc, mapped} ->
        {acc, mapped ++ [{:op, "!="}]}

      {kind, _text} = part, {acc, mapped} when kind in [:op, :join] ->
        {acc, mapped ++ [part]}

      value, {acc, mapped} ->
        {acc, value} = map_value(acc, value, line)
        {acc, mapped ++ [value]}
    end)
  end

  defp map_value(state, {:range, _from, _to} = range, line) do
    {finding(state, :cannot, "range", line, "ranges are not part of Relay's language"), range}
  end

  defp map_value(state, {:str, text} = value, line) do
    if Expr.printable_string?(text),
      do: {state, value},
      else: {finding(state, :cannot, "string_quotes", line, "a string holds both quotes"), value}
  end

  defp map_value(state, {:var, root, accesses}, line) do
    {state, accesses} =
      Enum.reduce(accesses, {state, []}, fn
        {:index, value}, {acc, mapped} ->
          {acc, value} = map_value(acc, value, line)
          {acc, mapped ++ [{:index, value}]}

        access, {acc, mapped} ->
          {acc, mapped ++ [access]}
      end)

    var = {:var, root, accesses}

    if MapSet.member?(state.locals, root) do
      {state, var}
    else
      case Expr.rename(var, state.aliases) do
        {renamed, nil} -> {state, renamed}
        {renamed, name} -> {%{state | used: MapSet.put(state.used, name)}, renamed}
      end
    end
  end

  defp map_value(state, value, _line), do: {state, value}

  defp parse(markup, parser) do
    with {:ok, tokens} <- lex(markup, []),
         {:ok, result, []} <- parser.(tokens) do
      {:ok, result}
    else
      _other -> :error
    end
  end

  defp expression(tokens) do
    with {:ok, value, rest} <- value(tokens),
         {:ok, filters, rest} <- filters(rest, []) do
      {:ok, {value, filters}, rest}
    end
  end

  defp whole_value(tokens), do: value(tokens)

  defp assignment([{:id, name}, :assign | rest]) do
    with {:ok, expression, rest} <- expression(rest), do: {:ok, {name, expression}, rest}
  end

  defp assignment(_tokens), do: :error

  defp capture_name([{:id, name}]), do: {:ok, name, []}
  defp capture_name([{:str, name}]), do: {:ok, name, []}
  defp capture_name(_tokens), do: :error

  defp loop([{:id, var}, {:id, "in"} | rest]) do
    with {:ok, collection, rest} <- value(rest),
         {:ok, params, flags} <- loop_params(rest, [], []) do
      {:ok, {var, collection, params, flags}, []}
    end
  end

  defp loop(_tokens), do: :error

  defp loop_params([], params, flags), do: {:ok, Enum.reverse(params), Enum.reverse(flags)}

  defp loop_params([{:id, "reversed"} | rest], params, flags),
    do: loop_params(rest, params, [:reversed | flags])

  defp loop_params([{:id, "offset"}, :colon, {:id, "continue"} | rest], params, flags),
    do: loop_params(rest, params, [:continue | flags])

  defp loop_params([{:id, name}, :colon | rest], params, flags)
       when name in ["limit", "offset"] do
    with {:ok, value, rest} <- value(rest),
         do: loop_params(rest, [{name, value} | params], flags)
  end

  defp loop_params(_tokens, _params, _flags), do: :error

  defp when_values(tokens) do
    with {:ok, value, rest} <- value(tokens) do
      case rest do
        [] -> {:ok, [value], []}
        [:comma | rest] -> more_when(rest, value)
        [{:id, "or"} | rest] -> more_when(rest, value)
        _other -> :error
      end
    end
  end

  defp more_when(rest, value) do
    with {:ok, values, rest} <- when_values(rest), do: {:ok, [value | values], rest}
  end

  defp condition(tokens), do: condition(tokens, [])

  defp condition(tokens, acc) do
    with {:ok, left, rest} <- value(tokens) do
      case rest do
        [{:op, op} | rest] -> right(rest, [{:op, op}, left | acc])
        [{:id, "contains"} | rest] -> right(rest, [{:op, "contains"}, left | acc])
        rest -> joined(rest, [left | acc])
      end
    end
  end

  defp right(tokens, acc) do
    with {:ok, value, rest} <- value(tokens), do: joined(rest, [value | acc])
  end

  defp joined([], acc), do: {:ok, Enum.reverse(acc), []}

  defp joined([{:id, join} | rest], acc) when join in ["and", "or"],
    do: condition(rest, [{:join, join} | acc])

  defp joined(_tokens, _acc), do: :error

  defp value([{:str, text} | rest]), do: {:ok, {:str, text}, rest}
  defp value([{:num, text} | rest]), do: {:ok, {:num, text}, rest}
  defp value([{:id, "true"} | rest]), do: {:ok, {:bool, true}, rest}
  defp value([{:id, "false"} | rest]), do: {:ok, {:bool, false}, rest}
  defp value([{:id, name} | rest]) when name in ["nil", "null"], do: {:ok, nil, rest}

  defp value([{:id, name} | rest]) when name in ["empty", "blank"],
    do: {:ok, {:special, name}, rest}

  defp value([:lparen | rest]) do
    with {:ok, from, [:dotdot | rest]} <- value(rest),
         {:ok, to, [:rparen | rest]} <- value(rest) do
      {:ok, {:range, from, to}, rest}
    else
      _other -> :error
    end
  end

  defp value([{:id, name} | rest]), do: accesses(rest, {:var, name, []})
  defp value(_tokens), do: :error

  defp accesses([:dot, {:id, name} | rest], {:var, root, list}),
    do: accesses(rest, {:var, root, list ++ [{:dot, name}]})

  defp accesses([:lbracket | rest], {:var, root, list}) do
    case value(rest) do
      {:ok, index, [:rbracket | rest]} -> accesses(rest, {:var, root, list ++ [{:index, index}]})
      _other -> :error
    end
  end

  defp accesses(rest, var), do: {:ok, var, rest}

  defp filters([:pipe, {:id, name} | rest], acc) do
    case filter_arguments(rest) do
      {:ok, args, rest} -> filters(rest, [{name, args} | acc])
      _other -> :error
    end
  end

  defp filters(rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp filter_arguments([:colon | rest]), do: argument_list(rest, [])
  defp filter_arguments(rest), do: {:ok, [], rest}

  defp argument_list([{:id, key}, :colon | rest], acc) do
    with {:ok, value, rest} <- value(rest), do: more_arguments(rest, [{key, value} | acc])
  end

  defp argument_list(tokens, acc) do
    with {:ok, value, rest} <- value(tokens), do: more_arguments(rest, [value | acc])
  end

  defp more_arguments([:comma | rest], acc), do: argument_list(rest, acc)
  defp more_arguments(rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp lex(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  defp lex(<<char, rest::binary>>, acc) when char in [?\s, ?\t, ?\n, ?\r], do: lex(rest, acc)
  defp lex(<<"..", rest::binary>>, acc), do: lex(rest, [:dotdot | acc])

  defp lex(<<op::binary-size(2), rest::binary>>, acc) when op in ["==", "!=", "<>", "<=", ">="],
    do: lex(rest, [{:op, op} | acc])

  defp lex(<<char, rest::binary>>, acc) when char in [?<, ?>],
    do: lex(rest, [{:op, <<char>>} | acc])
  defp lex(<<?., rest::binary>>, acc), do: lex(rest, [:dot | acc])
  defp lex(<<?[, rest::binary>>, acc), do: lex(rest, [:lbracket | acc])
  defp lex(<<?], rest::binary>>, acc), do: lex(rest, [:rbracket | acc])
  defp lex(<<?(, rest::binary>>, acc), do: lex(rest, [:lparen | acc])
  defp lex(<<?), rest::binary>>, acc), do: lex(rest, [:rparen | acc])
  defp lex(<<?|, rest::binary>>, acc), do: lex(rest, [:pipe | acc])
  defp lex(<<?:, rest::binary>>, acc), do: lex(rest, [:colon | acc])
  defp lex(<<?,, rest::binary>>, acc), do: lex(rest, [:comma | acc])
  defp lex(<<?=, rest::binary>>, acc), do: lex(rest, [:assign | acc])

  defp lex(<<quote, rest::binary>>, acc) when quote in [?", ?'] do
    case :binary.match(rest, <<quote>>) do
      {at, 1} ->
        text = binary_part(rest, 0, at)
        lex(binary_part(rest, at + 1, byte_size(rest) - at - 1), [{:str, text} | acc])

      :nomatch ->
        :error
    end
  end

  defp lex(<<char, _rest::binary>> = source, acc) when char in ?0..?9 or char == ?-,
    do: number(source, acc)

  defp lex(<<char, _rest::binary>> = source, acc)
       when char in ?a..?z or char in ?A..?Z or char == ?_,
       do: word(source, acc)

  defp lex(_source, _acc), do: :error

  defp number("-" <> rest, acc), do: number_digits("-", rest, acc)
  defp number(rest, acc), do: number_digits("", rest, acc)

  defp number_digits(sign, rest, acc) do
    case digits(rest, "") do
      {"", _rest} -> :error
      {whole, rest} -> fraction(sign <> whole, rest, acc)
    end
  end

  defp fraction(text, <<?., digit, rest::binary>>, acc) when digit in ?0..?9 do
    {part, rest} = digits(<<digit, rest::binary>>, "")
    lex(rest, [{:num, text <> "." <> part} | acc])
  end

  defp fraction(text, rest, acc), do: lex(rest, [{:num, text} | acc])

  defp digits(<<digit, rest::binary>>, acc) when digit in ?0..?9,
    do: digits(rest, acc <> <<digit>>)

  defp digits(rest, acc), do: {acc, rest}

  defp word(source, acc) do
    {name, rest} = word_chars(source, "")

    case rest do
      "?" <> rest -> lex(rest, [{:id, name <> "?"} | acc])
      rest -> lex(rest, [{:id, name} | acc])
    end
  end

  defp word_chars(<<char, rest::binary>>, acc)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?_, ?-],
       do: word_chars(rest, acc <> <<char>>)

  defp word_chars(rest, acc), do: {acc, rest}
end
