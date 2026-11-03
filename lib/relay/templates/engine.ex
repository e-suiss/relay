defmodule Relay.Templates.Engine do
  @moduledoc """
  The template engine: Liquid through Solid, which runs no code (TP-2), restricted to the TP-45 language.

  Tags: `if`/`elsif`/`else`, `unless`, `case`/`when`, `for` (only `limit` and `offset`, with an `else` branch), `break`, `continue`, `assign`, `capture`, `raw` and `comment`. Any other tag, including `include`, `render`, `cycle`, `tablerow`, `increment`, `decrement`, `echo`, `liquid` and the inline `#` comment, is a parse error; the engine has no file system (TP-4). Filters come only from `Relay.Templates.Filters`; an unknown filter, a wrong argument count and `raw` without the template's `allow_raw` flag are parse errors. Ranges are not part of the language, so a loop iterates only over data. Rendering is strict about variables and filters.

  The static limits of the publication gate (TP-6) are checked on the parsed tree: source at most 256 KB, at most 10 loops, loops nested at most 2 deep, at most 5,000 nodes. Nested access is at most 5 deep (TP-5).
  """

  alias Relay.Templates.Context
  alias Relay.Templates.Filters
  alias Solid.Tags

  @enforce_keys [:tree, :allow_raw]
  defstruct [:tree, :allow_raw]

  @type t :: %__MODULE__{tree: Solid.Parser.parse_tree(), allow_raw: boolean()}
  @type finding :: %{code: String.t(), detail: String.t(), line: pos_integer() | nil}
  @type stats :: %{
          nodes: non_neg_integer(),
          loops: non_neg_integer(),
          loop_depth: non_neg_integer()
        }
  @type reason :: {:missing_variable, String.t()} | {:schema_violation, String.t()}

  @tags %{
    "assign" => Tags.AssignTag,
    "break" => Tags.BreakTag,
    "capture" => Tags.CaptureTag,
    "case" => Tags.CaseTag,
    "comment" => Tags.CommentTag,
    "continue" => Tags.ContinueTag,
    "for" => Tags.ForTag,
    "if" => Tags.IfTag,
    "raw" => Tags.RawTag,
    "unless" => Tags.IfTag
  }

  @max_source_bytes 256 * 1024
  @max_loops 10
  @max_loop_depth 2
  @max_nodes 5_000
  @liquid_tag ~r/\{%-?\s*liquid(?![A-Za-z0-9_-])/

  # TP-45
  @doc "The tags a template may use."
  @spec tags() :: [String.t()]
  def tags, do: Map.keys(@tags)

  # TP-6
  @doc "The static limits of the publication gate."
  @spec limits() :: %{
          source_bytes: pos_integer(),
          loops: pos_integer(),
          loop_depth: pos_integer(),
          nodes: pos_integer()
        }
  def limits do
    %{
      source_bytes: @max_source_bytes,
      loops: @max_loops,
      loop_depth: @max_loop_depth,
      nodes: @max_nodes
    }
  end

  # TP-2
  # TP-4
  # TP-6
  # TP-45
  @doc "Parses a template source; the findings name every violation of the language and of the static limits. Option: `allow_raw` (default false)."
  @spec parse(String.t(), keyword()) :: {:ok, t()} | {:error, [finding()]}
  def parse(source, opts \\ []) when is_binary(source) do
    allow_raw = Keyword.get(opts, :allow_raw, false) == true

    cond do
      byte_size(source) > @max_source_bytes ->
        {:error, [finding("source_too_large", "the source exceeds 256 KB", nil)]}

      not String.valid?(source) ->
        {:error, [finding("invalid_utf8", "the source is not valid UTF-8", nil)]}

      true ->
        parse_valid(source, allow_raw)
    end
  end

  defp parse_valid(source, allow_raw) do
    liquid = liquid_findings(source)

    case Solid.parse(source, tags: @tags) do
      {:ok, %Solid.Template{parsed_template: tree}} ->
        findings = liquid ++ language(tree, allow_raw) ++ check_limits(tree)

        if findings == [],
          do: {:ok, %__MODULE__{tree: output_tree(tree), allow_raw: allow_raw}},
          else: {:error, findings}

      {:error, %Solid.TemplateError{errors: errors}} ->
        {:error, liquid ++ Enum.map(errors, &parse_finding/1)}
    end
  end

  defp liquid_findings(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line} ->
      if Regex.match?(@liquid_tag, text),
        do: [finding("tag_not_allowed", "the liquid tag is not allowed", line)],
        else: []
    end)
  end

  defp parse_finding(%Solid.ParserError{reason: reason, meta: meta}) do
    code = if String.starts_with?(reason, "Unexpected tag"), do: "tag_not_allowed", else: "syntax"
    finding(code, reason, meta[:line])
  end

  # TP-6
  @doc "Counts the nodes, the loops and the deepest loop nesting of a parsed tree."
  @spec stats(t() | Solid.Parser.parse_tree()) :: stats()
  def stats(%__MODULE__{tree: tree}), do: stats(tree)

  def stats(tree) when is_list(tree),
    do: count(tree, 0, %{nodes: 0, loops: 0, loop_depth: 0})

  # TP-6
  @doc "Returns the static limit findings of a parsed template; none means it is within the limits."
  @spec check_limits(t() | Solid.Parser.parse_tree()) :: [finding()]
  def check_limits(template) do
    %{nodes: nodes, loops: loops, loop_depth: depth} = stats(template)

    [
      {loops > @max_loops, "too_many_loops", "more than #{@max_loops} loops"},
      {depth > @max_loop_depth, "loops_too_deep", "loops nested too deep"},
      {nodes > @max_nodes, "too_many_nodes", "more than #{@max_nodes} nodes"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(fn {_, code, detail} -> finding(code, detail, nil) end)
  end

  defp count(entries, depth, acc) when is_list(entries),
    do: Enum.reduce(entries, acc, &count(&1, depth, &2))

  defp count(%Tags.ForTag{} = tag, depth, acc) do
    acc = %{
      acc
      | nodes: acc.nodes + 1,
        loops: acc.loops + 1,
        loop_depth: max(acc.loop_depth, depth + 1)
    }

    count(tag.else_body, depth, count(tag.body, depth + 1, acc))
  end

  defp count(%Tags.IfTag{} = tag, depth, acc) do
    acc = bump(acc, 1 + conditions(tag.condition))

    acc =
      Enum.reduce(tag.elsifs, acc, fn {condition, body}, acc ->
        count(body, depth, bump(acc, conditions(condition)))
      end)

    count(tag.else_body, depth, count(tag.body, depth, acc))
  end

  defp count(%Tags.CaseTag{cases: cases}, depth, acc) do
    Enum.reduce(cases, bump(acc, 1), fn {_when, body}, acc ->
      count(body, depth, bump(acc, 1))
    end)
  end

  defp count(%Tags.CaptureTag{body: body}, depth, acc), do: count(body, depth, bump(acc, 1))

  defp count(%Tags.AssignTag{object: %Solid.Object{filters: filters}}, _depth, acc),
    do: bump(acc, 1 + length(filters))

  defp count(%Solid.Object{filters: filters}, _depth, acc),
    do: bump(acc, 1 + Enum.count(filters, &(&1.function != Filters.output_filter())))

  defp count(_entry, _depth, acc), do: bump(acc, 1)

  defp bump(acc, by), do: %{acc | nodes: acc.nodes + by}

  defp conditions(nil), do: 0
  defp conditions({_relation, condition}), do: conditions(condition)

  defp conditions(%{child_condition: child}), do: 1 + conditions(child)

  defp language(tree, allow_raw), do: walk(tree, allow_raw, [])

  defp walk(entries, allow_raw, acc) when is_list(entries),
    do: Enum.reduce(entries, acc, &walk(&1, allow_raw, &2))

  defp walk(%Solid.Object{} = object, allow_raw, acc), do: object_findings(object, allow_raw, acc)

  defp walk(%Tags.AssignTag{object: object, argument: target}, allow_raw, acc),
    do: object_findings(object, allow_raw, argument(target, acc))

  defp walk(%Tags.CaptureTag{body: body, argument: target}, allow_raw, acc),
    do: walk(body, allow_raw, argument(target, acc))

  defp walk(%Tags.IfTag{} = tag, allow_raw, acc) do
    acc = condition(tag.condition, allow_raw, acc)

    acc =
      Enum.reduce(tag.elsifs, acc, fn {condition, body}, acc ->
        walk(body, allow_raw, condition(condition, allow_raw, acc))
      end)

    walk(tag.else_body, allow_raw, walk(tag.body, allow_raw, acc))
  end

  defp walk(%Tags.CaseTag{argument: subject, cases: cases}, allow_raw, acc) do
    Enum.reduce(cases, argument(subject, acc), fn
      {:else, body}, acc -> walk(body, allow_raw, acc)
      {values, body}, acc -> walk(body, allow_raw, Enum.reduce(values, acc, &argument/2))
    end)
  end

  defp walk(%Tags.ForTag{} = tag, allow_raw, acc) do
    acc =
      if tag.reversed,
        do: [finding("for_reversed", "for takes only limit and offset", tag.loc.line) | acc],
        else: acc

    acc = Enum.reduce(Map.values(tag.parameters), argument(tag.enumerable, acc), &argument/2)
    walk(tag.else_body, allow_raw, walk(tag.body, allow_raw, acc))
  end

  defp walk(_entry, _allow_raw, acc), do: acc

  defp condition(nil, _allow_raw, acc), do: acc
  defp condition({_relation, child}, allow_raw, acc), do: condition(child, allow_raw, acc)

  defp condition(%Solid.BinaryCondition{} = condition, allow_raw, acc) do
    acc = argument(condition.left_argument, acc)
    acc = argument(condition.right_argument, acc)
    list = condition.left_argument_filters ++ condition.right_argument_filters
    acc = filters(list, allow_raw, acc)
    condition(condition.child_condition, allow_raw, acc)
  end

  defp condition(%Solid.UnaryCondition{} = condition, allow_raw, acc) do
    acc = filters(condition.argument_filters, allow_raw, argument(condition.argument, acc))
    condition(condition.child_condition, allow_raw, acc)
  end

  defp object_findings(%Solid.Object{argument: subject, filters: list}, allow_raw, acc),
    do: filters(list, allow_raw, argument(subject, acc))

  defp filters(list, allow_raw, acc), do: Enum.reduce(list, acc, &filter(&1, allow_raw, &2))

  defp filter(%Solid.Filter{} = filter, allow_raw, acc) do
    acc = Enum.reduce(filter.positional_arguments, acc, &argument/2)
    acc = filter.named_arguments |> Map.values() |> Enum.reduce(acc, &argument/2)
    filter_findings(filter, allow_raw) ++ acc
  end

  defp filter_findings(%Solid.Filter{function: name, loc: loc} = filter, allow_raw) do
    positional = filter.positional_arguments
    named = filter.named_arguments
    line = loc && loc.line

    cond do
      Filters.arity(name) == nil ->
        [finding("filter_not_allowed", "the filter #{name} does not exist", line)]

      length(positional) not in Filters.arity(name) ->
        [finding("filter_arity", "wrong number of arguments for #{name}", line)]

      named != %{} and not Filters.named?(name) ->
        [finding("filter_arity", "#{name} takes no named arguments", line)]

      name == "raw" and not allow_raw ->
        [finding("raw_not_allowed", "raw needs the template's allow_raw flag", line)]

      true ->
        arguments(name, positional, named, line)
    end
  end

  defp arguments("truncate", [length | rest], _named, line) do
    literal? = match?(%Solid.Literal{value: value} when is_integer(value) and value >= 0, length)
    ellipsis? = Enum.all?(rest, &match?(%Solid.Literal{value: value} when is_binary(value), &1))

    if literal? and ellipsis?,
      do: [],
      else: [finding("filter_argument", "truncate takes a constant length", line)]
  end

  defp arguments(name, [digits], _named, line) when name in ["number", "percent"] do
    if match?(%Solid.Literal{value: value} when is_integer(value) and value in 0..10, digits),
      do: [],
      else: [finding("filter_argument", "#{name} takes constant fraction digits 0-10", line)]
  end

  defp arguments(name, [style], _named, line) when name in ["datetime", "date", "time"] do
    if match?(%Solid.Literal{value: value} when is_binary(value), style) and
         style.value in Filters.styles(),
       do: [],
       else: [finding("filter_argument", "#{name} takes short, medium, long or full", line)]
  end

  defp arguments("plural", [], named, line) do
    keys = Map.keys(named)

    literals? =
      Enum.all?(named, fn {_key, value} ->
        match?(%Solid.Literal{value: text} when is_binary(text), value)
      end)

    if "other" in keys and keys -- Filters.plural_keys() == [] and literals?,
      do: [],
      else: [finding("filter_argument", "plural takes constant forms and an other form", line)]
  end

  defp arguments(_name, _positional, _named, _line), do: []

  defp argument(%Solid.Range{loc: loc}, acc),
    do: [finding("range_not_allowed", "ranges are not part of the language", loc.line) | acc]

  defp argument(%Solid.Variable{identifier: nil, loc: loc}, acc),
    do: [finding("dynamic_root", "a variable starts with a name", loc.line) | acc]

  defp argument(%Solid.Variable{accesses: accesses, loc: loc}, acc) do
    acc =
      Enum.reduce(accesses, acc, fn
        %Solid.AccessVariable{variable: variable}, acc -> argument(variable, acc)
        _access, acc -> acc
      end)

    if length(accesses) + 1 > Context.max_depth(),
      do: [finding("access_too_deep", "nested access is too deep", loc.line) | acc],
      else: acc
  end

  defp argument(_literal, acc), do: acc

  defp output_tree(entries) when is_list(entries), do: Enum.map(entries, &output_tree/1)

  defp output_tree(%Solid.Object{} = object) do
    output = %Solid.Filter{
      loc: object.loc,
      function: Filters.output_filter(),
      positional_arguments: [],
      named_arguments: %{}
    }

    %{object | filters: object.filters ++ [output]}
  end

  defp output_tree(%Tags.IfTag{} = tag) do
    %{
      tag
      | body: output_tree(tag.body),
        elsifs: Enum.map(tag.elsifs, fn {condition, body} -> {condition, output_tree(body)} end),
        else_body: output_tree(tag.else_body)
    }
  end

  defp output_tree(%Tags.CaseTag{} = tag),
    do: %{tag | cases: Enum.map(tag.cases, fn {values, body} -> {values, output_tree(body)} end)}

  defp output_tree(%Tags.ForTag{} = tag),
    do: %{tag | body: output_tree(tag.body), else_body: output_tree(tag.else_body)}

  defp output_tree(%Tags.CaptureTag{} = tag), do: %{tag | body: output_tree(tag.body)}
  defp output_tree(entry), do: entry

  # TP-4
  # TP-7
  # TP-24
  @doc "Renders a parsed template with a context built for `channel`; the context of another channel is refused. Use `Relay.Templates.Sandbox` to render with the time and memory limits."
  @spec render(t(), Context.t(), Context.channel()) :: {:ok, String.t()} | {:error, reason()}
  def render(%__MODULE__{} = template, %Context{channel: channel} = context, channel) do
    state = %{
      locale: context.locale,
      tag: context.tag,
      time_zone: context.time_zone,
      escape: context.escape,
      isolate: context.isolate,
      allow_raw: template.allow_raw
    }

    options = [
      strict_variables: true,
      strict_filters: true,
      custom_filters: fn name, args -> Filters.run(name, args, state) end
    ]

    solid = %Solid.Template{parsed_template: template.tree, tags: @tags}

    case Solid.render(solid, context.vars, options) do
      {:ok, result, []} -> {:ok, IO.iodata_to_binary(result)}
      {:ok, _result, errors} -> {:error, reason(errors)}
      {:error, errors, _partial} -> {:error, reason(errors)}
    end
  end

  def render(%__MODULE__{}, %Context{channel: built_for}, channel) do
    raise ArgumentError,
          "a context built for #{inspect(built_for)} cannot render for #{inspect(channel)}"
  end

  defp reason(errors) do
    case Enum.find(errors, &match?(%Solid.UndefinedVariableError{}, &1)) do
      %Solid.UndefinedVariableError{original_name: name} -> {:missing_variable, to_string(name)}
      nil -> {:schema_violation, detail(hd(errors))}
    end
  end

  defp detail(%Solid.ArgumentError{message: message}) when is_binary(message), do: message
  defp detail(%Solid.UndefinedFilterError{filter: filter}),
    do: "the filter #{filter} does not exist"
  defp detail(_error), do: "the template cannot be rendered with this data"

  defp finding(code, detail, line), do: %{code: code, detail: detail, line: line}
end
