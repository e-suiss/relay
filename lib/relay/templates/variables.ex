defmodule Relay.Templates.Variables do
  @moduledoc """
  The variable contract of templates (TP-13 … TP-17).

  A path names a value the way a template reads it: object keys joined with `.`, an array element as `[]` (`order.items[].name`). Paths are extracted statically from the parsed tree and split into those read on every render and those read only inside a condition or a loop (TP-17). At publication the paths are validated against the JSON Schema 2020-12 event schema of the workflow version: a path the schema does not declare is an error, a string needs `maxLength`, a number needs `maximum`, a required array needs `minItems` of at least 1, money is `{amount: string, currency: string}` and the date filters read `format: date-time` strings (TP-14, TP-15, TP-16). `recipient.*` is validated against the recipient attribute schema, `brand.*` against the brand fields and the render helpers by name.

  The criticality of a variable (TP-14) is the schema keyword `x-relay-criticality` on its property: `required` (the default), `fallback` (needs `default`), `optional` (read only inside a condition) or `decorative`.
  """

  alias Relay.Templates.Context
  alias Relay.Templates.Engine
  alias Relay.Templates.Filters
  alias Relay.Templates.Samples
  alias Relay.Templates.Sandbox
  alias Solid.Tags

  @type segment :: String.t() | :index
  @type read :: %{
          path: String.t(),
          segments: [segment()],
          guarded: boolean(),
          test: boolean(),
          filter: String.t() | nil
        }
  @type usage :: %{always: [String.t()], conditional: [String.t()]}
  @type finding :: %{
          code: String.t(),
          path: String.t(),
          detail: String.t(),
          severity: :error | :warning
        }
  @type measures :: %{
          characters: non_neg_integer(),
          graphemes: non_neg_integer(),
          bytes: non_neg_integer(),
          sample: String.t()
        }

  @keyword "x-relay-criticality"
  @classes %{
    "required" => :required,
    "fallback" => :fallback,
    "optional" => :optional,
    "decorative" => :decorative
  }
  @brand_fields [
    "logo_url",
    "primary_color",
    "sender_name",
    "footer",
    "legal_name",
    "mersis",
    "contact",
    "postal_address"
  ]
  @helpers ~w(legal_footer unsubscribe_url)
  @pseudo ~w(size first last)
  @date_filters ~w(datetime date time)
  @worst_heap 256 * 1024 * 1024
  @worst_output 64 * 1024 * 1024
  @bounded_formats ~w(date-time date time)

  @doc "The brand fields a template may read under `brand`, unless the caller names others."
  @spec brand_fields() :: [String.t()]
  def brand_fields, do: @brand_fields

  @doc "The render helpers a template may read, unless the caller names others."
  @spec helpers() :: [String.t()]
  def helpers, do: @helpers

  @doc "Splits a path into its segments; `[]` is `:index`."
  @spec segments(String.t()) :: [segment()]
  def segments(path) when is_binary(path) do
    path
    |> String.split(".")
    |> Enum.flat_map(fn part ->
      case String.split(part, "[]") do
        [key] -> [key]
        [key | indexes] -> [key | Enum.map(indexes, fn _ -> :index end)]
      end
    end)
  end

  @doc "Joins segments into a path."
  @spec path([segment()]) :: String.t()
  def path(segments) do
    Enum.reduce(segments, "", fn
      :index, acc -> acc <> "[]"
      key, "" -> key
      key, acc -> acc <> "." <> key
    end)
  end

  # TP-17
  @doc "Every variable read of a parsed template, with whether it is guarded by a condition or a loop, whether it is a condition test and the first filter applied to it."
  @spec reads(Engine.t()) :: [read()]
  def reads(%Engine{tree: tree}) do
    {reads, _env} = walk(tree, false, %{}, [])
    Enum.reverse(reads)
  end

  # TP-17
  @doc "The paths a template reads on every render and those it reads only conditionally."
  @spec extract(Engine.t()) :: usage()
  def extract(%Engine{} = template) do
    reads = reads(template)
    always = for %{guarded: false, path: path} <- reads, uniq: true, do: path
    conditional = for %{guarded: true, path: path} <- reads, uniq: true, do: path
    conditional = conditional -- always
    %{always: Enum.sort(always), conditional: Enum.sort(conditional)}
  end

  defp walk(entries, guarded, env, acc) when is_list(entries) do
    Enum.reduce(entries, {acc, env}, fn entry, {acc, env} -> walk(entry, guarded, env, acc) end)
  end

  defp walk(%Solid.Object{} = object, guarded, env, acc),
    do: {object(object, guarded, env, acc), env}

  defp walk(%Tags.AssignTag{argument: target, object: object}, guarded, env, acc) do
    acc = object(object, guarded, env, acc)

    binding =
      case object do
        %Solid.Object{argument: %Solid.Variable{} = variable, filters: []} ->
          case resolve(variable, env) do
            {:ok, segments} -> {:alias, segments}
            :skip -> :local
          end

        _ ->
          :local
      end

    {acc, Map.put(env, name(target), binding)}
  end

  defp walk(%Tags.CaptureTag{argument: target, body: body}, guarded, env, acc) do
    {acc, env} = walk(body, guarded, env, acc)
    {acc, Map.put(env, name(target), :local)}
  end

  defp walk(%Tags.IfTag{} = tag, guarded, env, acc) do
    acc = condition(tag.condition, guarded, env, acc)
    {acc, env} = walk(tag.body, true, env, acc)

    {acc, env} =
      Enum.reduce(tag.elsifs, {acc, env}, fn {condition, body}, {acc, env} ->
        walk(body, true, env, condition(condition, true, env, acc))
      end)

    walk(tag.else_body, true, env, acc)
  end

  defp walk(%Tags.CaseTag{argument: subject, cases: cases}, guarded, env, acc) do
    acc = argument(subject, guarded, true, nil, env, acc)

    Enum.reduce(cases, {acc, env}, fn
      {:else, body}, {acc, env} ->
        walk(body, true, env, acc)

      {values, body}, {acc, env} ->
        acc = Enum.reduce(values, acc, &argument(&1, true, true, nil, env, &2))
        walk(body, true, env, acc)
    end)
  end

  defp walk(%Tags.ForTag{} = tag, guarded, env, acc) do
    acc = argument(tag.enumerable, guarded, true, nil, env, acc)

    acc =
      tag.parameters
      |> Map.values()
      |> Enum.reduce(acc, &argument(&1, guarded, false, nil, env, &2))

    loop = name(tag.variable)
    previous = Map.fetch(env, loop)

    binding =
      case tag.enumerable do
        %Solid.Variable{} = variable ->
          case resolve(variable, env) do
            {:ok, segments} -> {:alias, segments ++ [:index]}
            :skip -> :local
          end

        _ ->
          :local
      end

    {acc, env} = walk(tag.body, true, Map.put(env, loop, binding), acc)

    env =
      case previous do
        {:ok, value} -> Map.put(env, loop, value)
        :error -> Map.delete(env, loop)
      end

    walk(tag.else_body, true, env, acc)
  end

  defp walk(_entry, _guarded, env, acc), do: {acc, env}

  defp object(%Solid.Object{argument: subject, filters: filters}, guarded, env, acc) do
    filters = Enum.reject(filters, &(&1.function == Filters.output_filter()))
    first = filters |> List.first() |> then(&(&1 && &1.function))
    acc = argument(subject, guarded, false, first, env, acc)
    filter_arguments(filters, guarded, env, acc)
  end

  defp filter_arguments(filters, guarded, env, acc) do
    Enum.reduce(filters, acc, fn filter, acc ->
      arguments = filter.positional_arguments ++ Map.values(filter.named_arguments)
      Enum.reduce(arguments, acc, &argument(&1, guarded, false, nil, env, &2))
    end)
  end

  defp condition(nil, _guarded, _env, acc), do: acc
  defp condition({_relation, child}, guarded, env, acc), do: condition(child, guarded, env, acc)

  defp condition(%Solid.BinaryCondition{} = condition, guarded, env, acc) do
    acc = argument(condition.left_argument, guarded, true, nil, env, acc)
    acc = argument(condition.right_argument, guarded, true, nil, env, acc)
    condition(condition.child_condition, guarded, env, acc)
  end

  defp condition(%Solid.UnaryCondition{} = condition, guarded, env, acc) do
    acc = argument(condition.argument, guarded, true, nil, env, acc)
    condition(condition.child_condition, guarded, env, acc)
  end

  defp argument(%Solid.Variable{} = variable, guarded, test, filter, env, acc) do
    acc =
      Enum.reduce(variable.accesses, acc, fn
        %Solid.AccessVariable{variable: inner}, acc ->
          argument(inner, guarded, false, nil, env, acc)

        _access, acc ->
          acc
      end)

    case resolve(variable, env) do
      {:ok, segments} ->
        read = %{
          path: path(segments),
          segments: segments,
          guarded: guarded,
          test: test,
          filter: filter
        }

        [read | acc]

      :skip ->
        acc
    end
  end

  defp argument(_literal, _guarded, _test, _filter, _env, acc), do: acc

  defp resolve(%Solid.Variable{identifier: "forloop"}, _env), do: :skip

  defp resolve(%Solid.Variable{identifier: id, accesses: accesses}, env) when is_binary(id) do
    rest =
      Enum.map(accesses, fn
        %Solid.AccessLiteral{value: key} when is_binary(key) -> key
        _index -> :index
      end)

    case Map.get(env, id) do
      nil -> {:ok, [id | rest]}
      {:alias, base} -> {:ok, base ++ rest}
      :local -> :skip
    end
  end

  defp resolve(_variable, _env), do: :skip

  defp name(%Solid.Variable{identifier: id}) when is_binary(id), do: id
  defp name(other), do: to_string(other)

  # TP-14
  @doc "The criticality declarations of an event schema by path; a path without one is `required`."
  @spec criticality(map()) :: %{String.t() => Context.declaration()}
  def criticality(schema) when is_map(schema) do
    schema
    |> declarations(schema, [], 0)
    |> Map.new()
  end

  defp declarations(schema, root, prefix, depth) when depth < 32 do
    schema = deref(schema, root)

    own = own(prefix, schema)

    properties =
      for {key, child} <- Map.get(schema, "properties", %{}),
          is_map(child),
          declaration <- declarations(child, root, prefix ++ [key], depth + 1),
          do: declaration

    items =
      case Map.get(schema, "items") do
        %{} = items -> declarations(items, root, prefix ++ [:index], depth + 1)
        _ -> []
      end

    own ++ properties ++ items
  end

  defp declarations(_schema, _root, _prefix, _depth), do: []

  defp own([], _schema), do: []

  defp own(prefix, schema) do
    case Map.get(@classes, schema[@keyword]) do
      :fallback -> fallback(prefix, schema)
      class when class in [:optional, :decorative] -> [{path(prefix), %{class: class}}]
      _ -> []
    end
  end

  defp fallback(prefix, schema) do
    if Map.has_key?(schema, "default"),
      do: [{path(prefix), %{class: :fallback, default: schema["default"]}}],
      else: []
  end

  # TP-13
  # TP-14
  # TP-15
  # TP-16
  @doc """
  Validates the variables of a parsed template against an event schema. Options: `:recipient_schema` (the schema of the recipient attributes), `:brand_fields` and `:helpers` (the names allowed under `brand` and at the top level). An `:error` finding blocks publication; a `:warning` is recorded.
  """
  @spec validate(Engine.t(), map(), keyword()) :: [finding()]
  def validate(%Engine{} = template, schema, opts \\ []) when is_map(schema) do
    recipient = Keyword.get(opts, :recipient_schema, %{"type" => "object", "properties" => %{}})
    brand = Keyword.get(opts, :brand_fields, @brand_fields)
    helpers = Keyword.get(opts, :helpers, @helpers)

    template
    |> reads()
    |> Enum.flat_map(fn read ->
      case read.segments do
        ["brand" | rest] -> namespace(read, rest == [] or rest -- brand != [] or length(rest) > 1)
        [helper | rest] when helper != "recipient" -> helper(read, helper, rest, helpers, schema)
        ["recipient" | rest] -> check(read, rest, recipient)
      end
    end)
    |> Enum.uniq()
  end

  defp namespace(read, true), do: [undeclared(read)]
  defp namespace(_read, false), do: []

  defp helper(read, helper, rest, helpers, schema) do
    cond do
      helper in helpers and rest == [] -> []
      helper in helpers -> [undeclared(read)]
      true -> check(read, read.segments, schema)
    end
  end

  defp check(read, segments, schema) do
    case resolve_schema(schema, segments, schema, [], 0) do
      {:ok, leaf, chain} -> chain_findings(read, chain) ++ leaf_findings(read, leaf, chain)
      :error -> [undeclared(read)]
    end
  end

  defp resolve_schema(_schema, _segments, _root, _chain, depth) when depth > 64, do: :error

  defp resolve_schema(schema, [], root, chain, _depth), do: {:ok, deref(schema, root), chain}

  defp resolve_schema(schema, [segment | rest], root, chain, depth) when is_map(schema) do
    schema = deref(schema, root)
    properties = Map.get(schema, "properties", %{})

    cond do
      property?(properties, segment) ->
        child = properties[segment]
        entry = %{parent: schema, key: segment, schema: deref(child, root)}
        resolve_schema(child, rest, root, [entry | chain], depth + 1)

      element?(schema, segment) ->
        resolve_schema(schema["items"], rest, root, chain, depth + 1)

      pseudo?(schema, segment) ->
        pseudo(schema, segment, rest, root, chain, depth)

      true ->
        combined(schema, [segment | rest], root, chain, depth)
    end
  end

  defp resolve_schema(_schema, _segments, _root, _chain, _depth), do: :error

  defp property?(properties, segment), do: is_binary(segment) and is_map(properties[segment])
  defp element?(schema, segment), do: segment == :index and items?(schema)
  defp pseudo?(schema, segment), do: segment in @pseudo and (array?(schema) or string?(schema))
  defp items?(schema), do: array?(schema) and is_map(schema["items"])

  defp pseudo(_schema, "size", [], _root, chain, _depth), do: {:ok, :pseudo, chain}

  defp pseudo(schema, edge, rest, root, chain, depth) when edge in ["first", "last"] do
    cond do
      items?(schema) ->
        resolve_schema(schema["items"], rest, root, chain, depth + 1)

      string?(schema) and rest == [] ->
        {:ok, :pseudo, chain}

      true ->
        :error
    end
  end

  defp pseudo(_schema, _segment, _rest, _root, _chain, _depth), do: :error

  defp combined(schema, segments, root, chain, depth) do
    ["allOf", "anyOf", "oneOf"]
    |> Enum.flat_map(&List.wrap(schema[&1]))
    |> Enum.find_value(:error, fn subschema ->
      case resolve_schema(subschema, segments, root, chain, depth + 1) do
        {:ok, _leaf, _chain} = found -> found
        :error -> nil
      end
    end)
  end

  defp chain_findings(read, chain) do
    Enum.flat_map(chain, fn %{parent: parent, key: key, schema: schema} ->
      min_items(read, parent, key, schema) ++ money_amount(read, schema)
    end) ++ optional(read, chain)
  end

  defp min_items(read, parent, key, schema) do
    if array?(schema) and key in List.wrap(parent["required"]) and
         Map.get(schema, "minItems", 0) < 1,
       do: [error(read, "min_items_missing", "a required array needs minItems of at least 1")],
       else: []
  end

  defp money_amount(read, schema) do
    properties = Map.get(schema, "properties", %{})

    if is_map(properties["amount"]) and is_map(properties["currency"]) and
         not string?(properties["amount"]),
       do: [error(read, "money_amount_not_string", "a money amount is a string, never a float")],
       else: []
  end

  defp optional(%{guarded: false, test: false} = read, chain) do
    if Enum.any?(chain, &(&1.schema[@keyword] == "optional")),
      do: [error(read, "optional_unguarded", "an optional variable is read inside a condition")],
      else: []
  end

  defp optional(_read, _chain), do: []

  defp leaf_findings(_read, :pseudo, _chain), do: []

  defp leaf_findings(read, leaf, chain) do
    criticality_findings(read, chain) ++ filter_findings(read, leaf) ++ type_findings(read, leaf)
  end

  defp criticality_findings(read, [%{schema: schema} | _]) do
    case schema[@keyword] do
      nil ->
        []

      "fallback" when not is_map_key(schema, "default") ->
        [error(read, "fallback_default_missing", "a fallback variable needs a default")]

      class when is_map_key(@classes, class) ->
        []

      _ ->
        [error(read, "criticality_invalid", "criticality is not a known class")]
    end
  end

  defp criticality_findings(_read, []), do: []

  defp filter_findings(%{filter: "currency"} = read, leaf) do
    properties = Map.get(leaf, "properties", %{})

    if string?(properties["amount"] || %{}) and string?(properties["currency"] || %{}),
      do: [],
      else: [error(read, "money_shape", "currency reads {amount: string, currency: string}")]
  end

  defp filter_findings(%{filter: filter} = read, leaf) when filter in @date_filters do
    formats = if filter == "date", do: ["date-time", "date"], else: ["date-time"]

    if string?(leaf) and leaf["format"] in formats,
      do: [],
      else: [error(read, "date_time_format", "#{filter} reads a format: date-time string")]
  end

  defp filter_findings(_read, _leaf), do: []

  defp type_findings(read, leaf) do
    cond do
      unbounded_string?(leaf) ->
        [error(read, "max_length_missing", "a string variable needs maxLength")]

      unbounded_number?(leaf) ->
        [error(read, "maximum_missing", "a number variable needs maximum")]

      unbounded_array?(leaf) ->
        [warning(read, "max_items_missing", "an array without maxItems has no worst case")]

      unformatted_date_time?(read, leaf) ->
        [warning(read, "unformatted_date_time", "a date-time is printed without a date filter")]

      true ->
        []
    end
  end

  defp unbounded_string?(leaf), do: string?(leaf) and not bounded?(leaf)

  defp unbounded_number?(leaf),
    do: numeric?(leaf) and not Map.has_key?(leaf, "maximum") and not exclusive_maximum?(leaf)

  defp exclusive_maximum?(leaf), do: Map.has_key?(leaf, "exclusiveMaximum")
  defp unbounded_array?(leaf), do: array?(leaf) and not Map.has_key?(leaf, "maxItems")

  defp unformatted_date_time?(read, leaf) do
    string?(leaf) and leaf["format"] == "date-time" and read.filter not in @date_filters and
      not read.test
  end

  defp bounded?(schema) do
    Map.has_key?(schema, "maxLength") or Map.has_key?(schema, "enum") or
      Map.has_key?(schema, "const") or schema["format"] in @bounded_formats
  end

  defp types(schema) when is_map(schema), do: List.wrap(schema["type"])
  defp types(_schema), do: []

  defp array?(schema), do: "array" in types(schema)
  defp string?(schema), do: "string" in types(schema)
  defp numeric?(schema), do: Enum.any?(types(schema), &(&1 in ["number", "integer"]))

  defp deref(schema, root), do: deref(schema, root, 0)

  defp deref(%{"$ref" => "#" <> pointer}, root, depth) when depth < 32 do
    case pointer(root, pointer) do
      {:ok, target} -> deref(target, root, depth + 1)
      :error -> %{}
    end
  end

  defp deref(schema, _root, _depth) when is_map(schema), do: schema
  defp deref(_schema, _root, _depth), do: %{}

  defp pointer(root, ""), do: {:ok, root}

  defp pointer(root, "/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce_while({:ok, root}, fn key, {:ok, node} ->
      case node do
        %{^key => child} -> {:cont, {:ok, child}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp pointer(_root, _pointer), do: :error

  defp undeclared(read),
    do: error(read, "undeclared_variable", "#{read.path} is not declared in the schema")

  defp error(read, code, detail),
    do: %{code: code, path: read.path, detail: detail, severity: :error}

  defp warning(read, code, detail),
    do: %{code: code, path: read.path, detail: detail, severity: :warning}

  # TP-15
  @doc """
  Renders a template with the automatic boundary samples of its schema (`Relay.Templates.Samples.boundary/1`) and returns the largest output measures, to be compared with the channel limits at publication. Options: `:locale` (required), `:time_zone` (default `Etc/UTC`), `:part`, `:recipient`, `:brand`, `:helpers`.
  """
  @spec worst_case(Engine.t(), map(), Context.channel(), keyword()) ::
          {:ok, measures()} | {:error, {String.t(), Sandbox.reason()}}
  def worst_case(%Engine{} = template, schema, channel, opts) when is_map(schema) do
    fields = [
      locale: Keyword.fetch!(opts, :locale),
      time_zone: Keyword.get(opts, :time_zone, "Etc/UTC"),
      part: opts[:part],
      recipient: Keyword.get(opts, :recipient, %{}),
      brand: Keyword.get(opts, :brand, %{}),
      helpers: Keyword.get(opts, :helpers, %{})
    ]

    limits = [timeout_ms: 1_000, max_heap_bytes: @worst_heap, max_output_bytes: @worst_output]

    schema
    |> Samples.boundary()
    |> Enum.reduce_while({:ok, nil}, fn {name, data}, {:ok, worst} ->
      with {:ok, context} <- Context.new(channel, [data: data] ++ fields),
           {:ok, _output, measures} <- Sandbox.run(template, context, channel, limits) do
        {:cont, {:ok, larger(worst, Map.put(measures, :sample, name))}}
      else
        {:error, reason} -> {:halt, {:error, {name, reason}}}
      end
    end)
    |> case do
      {:ok, nil} -> {:ok, %{characters: 0, graphemes: 0, bytes: 0, sample: "none"}}
      {:ok, worst} -> {:ok, Map.take(worst, [:characters, :graphemes, :bytes, :sample])}
      error -> error
    end
  end

  defp larger(nil, measures), do: measures
  defp larger(worst, measures), do: if(measures.bytes > worst.bytes, do: measures, else: worst)
end
