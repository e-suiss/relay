defmodule Relay.Templates.Convert.Handlebars do
  @moduledoc """
  Converts Handlebars to Relay's Liquid subset (OP-96, OP-55 (9)). The source is parsed into a tree of text, mustaches, comments and blocks (with their `else` and `else if` branches); the tree is walked with the stack of Handlebars contexts, so a path inside `each` or `with` is written as the absolute Liquid path it reads, `../` climbs a context and `@root` starts at the root. `{{x}}` becomes an output, `{{{x}}}` and `{{&x}}` a `raw` output for review, `if`, `unless` and `{{^x}}` the Liquid tags for review because Handlebars treats an empty list, an empty string and zero as false and Liquid does not, `each` a `for` loop for review because Liquid iterates lists only (`@index`, `@first` and `@last` become `forloop` fields), `with` an `if` around its block, `lookup` an index access and comments comment blocks. Partials, decorators, raw blocks, subexpressions, `@key`, other helpers and other block helpers have no equivalent and cannot be converted; nothing is guessed.
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

  @whitespace [" ", "\t", "\n", "\r"]
  @plain {false, false}

  # OP-96
  # OP-55 (9)
  @doc "Converts a Handlebars source with the alias table `aliases` (old path to Relay path); answers the output tokens, the findings, the aliases used and whether a raw output was written."
  @spec convert(String.t(), %{String.t() => String.t()}) :: result()
  def convert(source, aliases) when is_binary(source) and is_map(aliases) do
    state = %{tokens: [], findings: [], aliases: aliases, used: MapSet.new(), raw: false}

    state =
      case tree(scan(source, 1, [])) do
        {:ok, nodes} -> walk(nodes, [:root], state)
        {:error, line, detail} -> finding(state, :cannot, "syntax", line, detail)
      end

    %{
      tokens: Enum.reverse(state.tokens),
      findings: Enum.reverse(state.findings),
      aliases: state.used |> MapSet.to_list() |> Enum.sort(),
      raw: state.raw
    }
  end

  defp scan("", _line, acc), do: Enum.reverse(acc)

  defp scan(source, line, acc) do
    case :binary.match(source, "{{") do
      :nomatch ->
        Enum.reverse([{:text, source, line} | acc])

      {at, 2} ->
        before = binary_part(source, 0, at)
        rest = binary_part(source, at + 2, byte_size(source) - at - 2)
        next = line + Scan.lines(before)

        if String.ends_with?(before, "\\") do
          literal = binary_part(before, 0, at - 1) <> "{{"
          scan(rest, next, [{:text, literal, line} | acc])
        else
          mustache(rest, next, text(acc, before, line))
        end
    end
  end

  defp text(acc, "", _line), do: acc
  defp text(acc, text, line), do: [{:text, text, line} | acc]

  defp mustache("{{" <> rest, line, acc) do
    acc = [{:unsupported, "raw_block", "raw blocks have no equivalent", line} | acc]

    case Scan.close_plain(rest, "}}}}") do
      {:ok, _inside, rest} -> scan(rest, line, acc)
      :error -> Enum.reverse(acc)
    end
  end

  defp mustache("{" <> rest, line, acc) do
    closed(Scan.close(rest, "}}}"), line, acc, fn inside ->
      {markup, trims} = Scan.trims(inside, "~")
      {:mustache, markup, false, trims, line}
    end)
  end

  defp mustache("!--" <> rest, line, acc),
    do: closed(Scan.close_plain(rest, "--}}"), line, acc, &{:comment, &1, line})

  defp mustache("~!--" <> rest, line, acc),
    do: closed(Scan.close_plain(rest, "--}}"), line, acc, &{:comment, &1, line})

  defp mustache("!" <> rest, line, acc),
    do: closed(Scan.close_plain(rest, "}}"), line, acc, &{:comment, &1, line})

  defp mustache("~!" <> rest, line, acc),
    do: closed(Scan.close_plain(rest, "}}"), line, acc, &{:comment, &1, line})

  defp mustache(rest, line, acc) do
    closed(Scan.close(rest, "}}"), line, acc, fn inside ->
      {markup, trims} = Scan.trims(inside, "~")
      classify(markup, trims, line)
    end)
  end

  defp closed({:ok, inside, rest}, line, acc, build) do
    item = build.(inside)
    scan(rest, line + Scan.lines(inside), [item | acc])
  end

  defp closed(:error, line, acc, _build),
    do: Enum.reverse([{:unclosed, line} | acc])

  defp classify("#>" <> _rest, _trims, line),
    do: {:unsupported, "partial", "partial blocks pull in another template", line}

  defp classify("#*" <> _rest, _trims, line),
    do: {:unsupported, "decorator", "decorators have no equivalent", line}

  defp classify("#" <> markup, trims, line) do
    {name, args} = split_name(String.trim(markup))
    {:open, name, args, :block, trims, line}
  end

  defp classify("^", trims, line), do: {:else, "", trims, line}

  defp classify("^" <> markup, trims, line) do
    {name, args} = split_name(String.trim(markup))
    {:open, name, args, :inverse, trims, line}
  end

  defp classify("/" <> name, trims, line), do: {:close, String.trim(name), trims, line}

  defp classify(">" <> _rest, _trims, line),
    do: {:unsupported, "partial", "partials pull in another template", line}

  defp classify("else", trims, line), do: {:else, "", trims, line}

  defp classify("else " <> args, trims, line), do: {:else, String.trim(args), trims, line}

  defp classify("&" <> markup, trims, line),
    do: {:mustache, String.trim(markup), false, trims, line}

  defp classify(markup, trims, line), do: {:mustache, markup, true, trims, line}

  defp split_name(markup) do
    case :binary.match(markup, @whitespace) do
      :nomatch ->
        {markup, ""}

      {at, _size} ->
        {binary_part(markup, 0, at),
         String.trim(binary_part(markup, at, byte_size(markup) - at))}
    end
  end

  defp tree(items), do: tree(items, [%{name: nil, line: nil, body: [], elses: []}])

  defp tree([], [root]), do: {:ok, Enum.reverse(root.body)}
  defp tree([], [frame | _rest]), do: {:error, frame.line, "#{frame.name} is never closed"}

  defp tree([{:unclosed, line} | _rest], _stack),
    do: {:error, line, "a mustache is never closed"}

  defp tree([{:open, name, args, kind, trims, line} | rest], stack) do
    frame = %{name: name, args: args, kind: kind, trims: trims, line: line, body: [], elses: []}
    tree(rest, [frame | stack])
  end

  defp tree([{:else, args, trims, line} | rest], [frame | stack]) when frame.name != nil do
    tree(rest, [%{frame | elses: frame.elses ++ [{args, trims, line, []}]} | stack])
  end

  defp tree([{:else, _args, _trims, line} | _rest], _stack),
    do: {:error, line, "else outside a block"}

  defp tree([{:close, name, trims, line} | rest], [frame, parent | stack]) do
    if name == frame.name do
      block = {:block, %{frame | body: Enum.reverse(frame.body)}, trims}
      tree(rest, [add(parent, block) | stack])
    else
      {:error, line, "/#{name} closes #{frame.name}"}
    end
  end

  defp tree([{:close, name, _trims, line} | _rest], _stack),
    do: {:error, line, "/#{name} closes nothing"}

  defp tree([item | rest], [frame | stack]), do: tree(rest, [add(frame, item) | stack])

  defp add(%{elses: []} = frame, item), do: %{frame | body: [item | frame.body]}

  defp add(%{elses: elses} = frame, item) do
    {args, trims, line, nodes} = List.last(elses)
    %{frame | elses: List.replace_at(elses, -1, {args, trims, line, nodes ++ [item]})}
  end

  defp walk(nodes, ctx, state), do: Enum.reduce(nodes, state, &visit(&1, ctx, &2))

  defp visit({:text, text, line}, _ctx, state) do
    if Expr.literal_text?(text),
      do: emit(state, {:text, text}),
      else: finding(state, :cannot, "literal_text", line, "the text holds Liquid delimiters")
  end

  defp visit({:comment, text, _line}, _ctx, state) do
    state
    |> emit({:tag, "comment", @plain})
    |> emit({:verbatim, text})
    |> emit({:tag, "endcomment", @plain})
  end

  defp visit({:unsupported, code, detail, line}, _ctx, state),
    do: finding(state, :cannot, code, line, detail)

  defp visit({:mustache, markup, escaped, trims, line}, ctx, state) do
    case parse(markup) do
      {:ok, call} -> output(call, {escaped, trims}, line, ctx, state)
      :error -> finding(state, :cannot, "syntax", line, "a mustache cannot be read")
    end
  end

  defp visit({:block, frame, end_trims}, ctx, state) do
    parsed = if frame.kind == :inverse, do: parse(frame.name), else: block_call(frame.args)

    case parsed do
      {:ok, call} -> block(frame.name, frame.kind, call, frame, end_trims, ctx, state)
      :error -> finding(state, :cannot, "syntax", frame.line, "#{frame.name} cannot be read")
    end
  end

  defp block_call(""), do: {:ok, %{value: nil, params: [], hash: [], block_params: []}}

  defp block_call(args) do
    case parse(args) do
      {:ok, call} -> {:ok, %{call | params: [call.value | call.params]}}
      :error -> :error
    end
  end

  defp output(%{params: [], hash: [], block_params: []} = call, how, line, ctx, state) do
    {state, value} = operand(call.value, line, ctx, state)
    raw(state, {value, []}, how, line)
  end

  defp output(%{value: {:path, 0, false, ["lookup"]}} = call, how, line, ctx, state) do
    case call do
      %{params: [object, key], hash: [], block_params: []} ->
        {state, object} = operand(object, line, ctx, state)
        {state, key} = lookup_key(key, line, ctx, state)
        raw(state, {index(object, key), []}, how, line)

      _other ->
        finding(state, :cannot, "syntax", line, "lookup takes an object and a key")
    end
  end

  defp output(%{value: {:path, 0, false, ["log"]}}, _how, line, _ctx, state),
    do: finding(state, :info, "log_dropped", line, "log writes nothing to the message")

  defp output(%{value: {:path, _depth, _data, segments}}, _how, line, _ctx, state) do
    detail = "the helper #{Enum.join(segments, ".")} has no Relay equivalent"
    finding(state, :cannot, "helper_without_equivalent", line, detail)
  end

  defp output(_call, _how, line, _ctx, state),
    do: finding(state, :cannot, "syntax", line, "a literal takes no arguments")

  defp raw(state, expression, {true, trims}, _line), do: emit(state, {:out, expression, trims})

  defp raw(state, {value, filters}, {false, trims}, line) do
    state = finding(state, :review, "raw_output", line, "an unescaped output needs allow_raw")
    emit(%{state | raw: true}, {:out, {value, filters ++ [{"raw", []}]}, trims})
  end

  defp lookup_key({:str, key}, _line, _ctx, state), do: {state, {:dot, key}}
  defp lookup_key({:num, number}, _line, _ctx, state), do: {state, {:index, {:num, number}}}

  defp lookup_key(key, line, ctx, state) do
    {state, value} = operand(key, line, ctx, state)
    {state, {:index, value}}
  end

  defp index({:var, root, accesses}, access), do: {:var, root, accesses ++ [access]}
  defp index(value, _access), do: value

  defp block(name, :block, call, frame, end_trims, ctx, state) when name in ["if", "unless"],
    do: branches(name, call, frame, end_trims, ctx, state)

  defp block(_name, :inverse, call, frame, end_trims, ctx, state) do
    case call do
      %{value: {:path, _depth, _data, _segments} = subject, params: [], hash: []} ->
        branches("unless", %{call | params: [subject]}, frame, end_trims, ctx, state)

      _other ->
        finding(state, :cannot, "syntax", frame.line, "an inverse block takes a path")
    end
  end

  defp block("each", :block, call, frame, end_trims, ctx, state) do
    case call do
      %{params: [collection], hash: [], block_params: names} when length(names) <= 2 ->
        loop(collection, names, frame, end_trims, ctx, state)

      _other ->
        finding(state, :cannot, "syntax", frame.line, "each takes one list")
    end
  end

  defp block("with", :block, call, frame, end_trims, ctx, state) do
    case call do
      %{params: [subject], hash: [], block_params: []} ->
        with_block(subject, frame, end_trims, ctx, state)

      _other ->
        finding(state, :cannot, "syntax", frame.line, "with takes one object")
    end
  end

  defp block(name, _kind, _call, frame, _end_trims, _ctx, state) do
    detail = "the block helper #{name} has no Relay equivalent"
    finding(state, :cannot, "helper_without_equivalent", frame.line, detail)
  end

  defp branches(tag, call, frame, end_trims, ctx, state) do
    case call do
      %{params: [subject], hash: [], block_params: []} ->
        {state, value} = operand(subject, frame.line, ctx, state)
        state = truthiness(state, frame.line)
        state = emit(state, {:tag, [tag, " ", Expr.value(value)], frame.trims})
        state = walk(frame.body, ctx, state)
        state = Enum.reduce(frame.elses, state, &branch(&1, tag, ctx, &2))
        emit(state, {:tag, "end" <> tag, end_trims})

      _other ->
        finding(state, :cannot, "syntax", frame.line, "#{tag} takes one value")
    end
  end

  defp branch({"", trims, _line, nodes}, _tag, ctx, state),
    do: walk(nodes, ctx, emit(state, {:tag, "else", trims}))

  defp branch({"if " <> args, trims, line, nodes}, "if", ctx, state) do
    case parse(args) do
      {:ok, %{params: [], hash: [], block_params: [], value: subject}} ->
        {state, value} = operand(subject, line, ctx, state)
        state = emit(state, {:tag, ["elsif ", Expr.value(value)], trims})
        walk(nodes, ctx, state)

      _other ->
        finding(state, :cannot, "syntax", line, "else if takes one value")
    end
  end

  defp branch({args, _trims, line, _nodes}, _tag, _ctx, state),
    do: finding(state, :cannot, "syntax", line, "else #{args} has no equivalent here")

  defp loop(collection, names, frame, end_trims, ctx, state) do
    {state, value} = operand(collection, frame.line, ctx, state)
    count = Enum.count(ctx, &match?({:loop, _var}, &1)) + 1
    var = loop_var(names, count)
    inner = [{:loop, var} | ctx]
    inner = if match?([_, _], names), do: [{:index, List.last(names)} | inner], else: inner

    state =
      state
      |> finding(:review, "each_assumes_list", frame.line, "Liquid iterates lists only")
      |> emit({:tag, ["for ", var, " in ", Expr.value(value)], frame.trims})
      |> then(&walk(frame.body, inner, &1))

    state =
      case frame.elses do
        [] -> state
        [{"", trims, _line, nodes}] -> walk(nodes, ctx, emit(state, {:tag, "else", trims}))
        _more -> finding(state, :cannot, "syntax", frame.line, "each takes one else")
      end

    emit(state, {:tag, "endfor", end_trims})
  end

  defp loop_var([name | _rest], _count), do: name
  defp loop_var([], 1), do: "item"
  defp loop_var([], count), do: "item#{count}"

  defp with_block(subject, frame, end_trims, ctx, state) do
    {state, value} = operand(subject, frame.line, ctx, state)
    state = truthiness(state, frame.line)
    state = emit(state, {:tag, ["if ", Expr.value(value)], frame.trims})
    state = walk(frame.body, [{:with, value} | ctx], state)

    state =
      case frame.elses do
        [] -> state
        [{"", trims, _line, nodes}] -> walk(nodes, ctx, emit(state, {:tag, "else", trims}))
        _more -> finding(state, :cannot, "syntax", frame.line, "with takes one else")
      end

    emit(state, {:tag, "endif", end_trims})
  end

  defp truthiness(state, line) do
    detail = "Handlebars treats an empty list, an empty string and 0 as false; Liquid does not"
    finding(state, :review, "truthiness_differs", line, detail)
  end

  defp operand({:path, depth, true, segments}, line, ctx, state),
    do: data(depth, segments, line, ctx, state)

  defp operand({:path, depth, false, segments}, line, ctx, state) do
    frames = Enum.drop(Enum.reject(ctx, &match?({:index, _name}, &1)), depth)
    index_name = index_name(ctx)

    cond do
      depth == 0 and index_name != nil and segments == [index_name] ->
        {state, {:var, "forloop", [{:dot, "index0"}]}}

      frames == [] ->
        cannot_value(state, "path_outside_root", line, "the path climbs above the root")

      true ->
        base(hd(frames), segments, line, ctx, state)
    end
  end

  defp index_name(ctx) do
    case Enum.find(ctx, &match?({tag, _name} when tag in [:loop, :index], &1)) do
      {:index, name} -> name
      _loop_or_none -> nil
    end
  end

  defp operand(literal, line, _ctx, state) do
    case literal do
      {:str, text} ->
        if Expr.printable_string?(text),
          do: {state, literal},
          else: cannot_value(state, "string_quotes", line, "a string holds both quotes")

      other ->
        {state, other}
    end
  end

  defp base(:root, [], line, _ctx, state),
    do: cannot_value(state, "root_context_output", line, "the root context has no Liquid name")

  defp base(:root, [root | rest], line, ctx, state) do
    loops = for {:loop, var} <- ctx, do: var

    cond do
      not Expr.identifier?(root) ->
        cannot_value(state, "path_segment", line, "#{root} is not a Liquid name")

      root in loops or root == "forloop" ->
        cannot_value(state, "name_collision", line, "#{root} is also a loop variable")

      true ->
        renamed({:var, root, Enum.map(rest, &{:dot, &1})}, state)
    end
  end

  defp base({:loop, var}, segments, _line, _ctx, state),
    do: {state, {:var, var, Enum.map(segments, &{:dot, &1})}}

  defp base({:with, {:var, root, accesses}}, segments, _line, _ctx, state),
    do: {state, {:var, root, accesses ++ Enum.map(segments, &{:dot, &1})}}

  defp base({:with, _literal}, _segments, line, _ctx, state),
    do: cannot_value(state, "syntax", line, "with takes an object")

  defp renamed(var, state) do
    case Expr.rename(var, state.aliases) do
      {value, nil} -> {state, value}
      {value, name} -> {%{state | used: MapSet.put(state.used, name)}, value}
    end
  end

  defp data(0, ["root" | segments], line, _ctx, state) when segments != [],
    do: base(:root, segments, line, [], state)

  defp data(0, [name], line, ctx, state) when name in ["index", "first", "last"] do
    case Enum.find(ctx, &match?({:loop, _var}, &1)) do
      nil ->
        cannot_value(state, "data_variable", line, "@#{name} is used outside each")

      _loop ->
        field = if name == "index", do: "index0", else: name
        {state, {:var, "forloop", [{:dot, field}]}}
    end
  end

  defp data(_depth, ["key"], line, _ctx, state),
    do: cannot_value(state, "object_iteration", line, "@key iterates an object")

  defp data(_depth, segments, line, _ctx, state) do
    detail = "@#{Enum.join(segments, ".")} has no Relay equivalent"
    cannot_value(state, "data_variable", line, detail)
  end

  defp cannot_value(state, code, line, detail),
    do: {finding(state, :cannot, code, line, detail), nil}

  defp emit(state, token), do: %{state | tokens: [token | state.tokens]}

  defp finding(state, severity, code, line, detail),
    do: %{state | findings: [{severity, code, line, detail} | state.findings]}

  defp parse(markup) do
    with {:ok, tokens} <- lex(markup, []),
         [first | rest] <- tokens,
         {:ok, value} <- literal_or_path(first),
         {:ok, params, hash, names} <- arguments(rest, [], [], []) do
      {:ok, %{value: value, params: params, hash: hash, block_params: names}}
    else
      _other -> :error
    end
  end

  defp arguments([], params, hash, names),
    do: {:ok, Enum.reverse(params), Enum.reverse(hash), names}

  defp arguments([{:word, "as"}, :bar | rest], params, hash, []) do
    case Enum.split_while(rest, &match?({:word, _}, &1)) do
      {words, [:bar]} when words != [] ->
        names = Enum.map(words, fn {:word, name} -> name end)

        if Enum.all?(names, &Expr.identifier?/1),
          do: arguments([], params, hash, names),
          else: :error

      _other ->
        :error
    end
  end

  defp arguments([{:word, key}, :eq, token | rest], params, hash, names) do
    with {:ok, value} <- literal_or_path(token),
         do: arguments(rest, params, [{key, value} | hash], names)
  end

  defp arguments([token | rest], params, hash, names) do
    with {:ok, value} <- literal_or_path(token),
         do: arguments(rest, [value | params], hash, names)
  end

  defp literal_or_path({:str, text}), do: {:ok, {:str, text}}
  defp literal_or_path({:num, text}), do: {:ok, {:num, text}}
  defp literal_or_path({:word, "true"}), do: {:ok, {:bool, true}}
  defp literal_or_path({:word, "false"}), do: {:ok, {:bool, false}}
  defp literal_or_path({:word, word}) when word in ["null", "undefined"], do: {:ok, nil}
  defp literal_or_path({:word, word}), do: path(word)
  defp literal_or_path(_token), do: :error

  defp path("@" <> rest), do: path_parts(rest, true)
  defp path(text), do: path_parts(text, false)

  defp path_parts(text, data) do
    {depth, text} = climb(text, 0)
    text = this(text)

    if String.contains?(text, ["[", "]"]) do
      :error
    else
      {:ok, {:path, depth, data, String.split(text, [".", "/"], trim: true)}}
    end
  end

  defp climb("../" <> rest, depth), do: climb(rest, depth + 1)
  defp climb(text, depth), do: {depth, text}

  defp this("this"), do: ""
  defp this("this." <> rest), do: rest
  defp this("this/" <> rest), do: rest
  defp this("./" <> rest), do: rest
  defp this(text), do: text

  defp lex(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  defp lex(<<char, rest::binary>>, acc) when char in [?\s, ?\t, ?\n, ?\r], do: lex(rest, acc)
  defp lex(<<?=, rest::binary>>, acc), do: lex(rest, [:eq | acc])
  defp lex(<<?|, rest::binary>>, acc), do: lex(rest, [:bar | acc])
  defp lex(<<char, _rest::binary>>, _acc) when char in [?(, ?)], do: :error

  defp lex(<<quote, rest::binary>>, acc) when quote in [?", ?'] do
    case :binary.match(rest, <<quote>>) do
      {at, 1} ->
        text = binary_part(rest, 0, at)
        lex(binary_part(rest, at + 1, byte_size(rest) - at - 1), [{:str, text} | acc])

      :nomatch ->
        :error
    end
  end

  defp lex(source, acc) do
    {word, rest} = word(source, "")

    cond do
      word == "" -> :error
      number?(word) -> lex(rest, [{:num, word} | acc])
      true -> lex(rest, [{:word, word} | acc])
    end
  end

  defp word(<<char, rest::binary>>, acc)
       when char not in [?\s, ?\t, ?\n, ?\r, ?=, ?|, ?(, ?), ?", ?'],
       do: word(rest, acc <> <<char>>)

  defp word(rest, acc), do: {acc, rest}

  defp number?(word) do
    digits = String.trim_leading(word, "-")

    digits != "" and
      Enum.all?(String.split(digits, ".", parts: 2), fn part ->
        part != "" and Enum.all?(:binary.bin_to_list(part), &(&1 in ?0..?9))
      end)
  end
end
