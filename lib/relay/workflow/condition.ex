defmodule Relay.Workflow.Condition do
  @moduledoc """
  The condition language of workflows (WF-10, WF-60), also the second-stage `match` condition of a waitpoint (AG-14): a JSON tree that compares and combines values, deterministic, without loops, function definitions, regular expressions or external calls. It is pure: `validate/2` checks a condition against what its place in a definition may read, and `evaluate/2` decides it against a context.

  A condition is one operator object. `eq`, `ne`, `lt`, `lte`, `gt`, `gte`, `in`, `not_in`, `contains`, `starts_with` and `ends_with` take two operands; `exists` takes one variable; `all` and `any` take a non-empty list of conditions and `not` one condition. An operand is `{"var": path}`, `{"time_add": [operand, duration]}` or a constant: a string of at most 256 bytes, a number, a boolean, `null`, or a list of at most 100 such scalars. Paths are `data.…` (the event data, segments of letters, digits, `_` and `-`, a digit segment indexing a list), `recipient.<attribute>` (declared in `recipient_attributes`), `steps.<key>.<result>` (a result of an earlier step: `delivered`, `failed`, `skipped`, `seen`, `read`, `clicked` (human clicks only), `throttled`, `timed_out`, `matched`), `event.time`, `run.started_at` and, in a `match` condition only, `incoming.…` (the incoming event's data).

  There is no type conversion: values compare only with values of the same kind (number, string, boolean, timestamp, `null`), and a type mismatch or a missing path gives `null` or `false`, never an error. Timestamps come from `event.time`, `run.started_at`, a recipient attribute declared `timestamp` and `time_add`, which also reads an RFC 3339 string as a timestamp; ordering compares numbers, strings (by bytes) and timestamps. A condition has at most 64 nodes (every operator and operand), nests at most 8 deep and its canonical JSON is at most 4 KiB.
  """

  @limits Relay.Limits.fetch!(["workflow"])
  @max_nodes @limits["condition_max_nodes"]
  @max_depth @limits["condition_max_depth"]
  @max_bytes @limits["condition_max_bytes"]
  @max_string @limits["condition_max_string_bytes"]
  @max_list @limits["condition_max_list"]

  @binary ~w(eq ne lt lte gt gte in not_in contains starts_with ends_with)
  @logical ~w(all any)
  @operators @binary ++ @logical ++ ~w(exists not)
  @results ~w(delivered failed skipped seen read clicked throttled timed_out matched)
  @segment ~r/\A[A-Za-z0-9_-]{1,128}\z/

  @type t :: map()
  @type field_error :: %{pointer: String.t(), code: String.t(), detail: String.t()}
  @type scope :: %{
          required(:attributes) => %{String.t() => String.t()},
          required(:steps) => MapSet.t(String.t()) | [String.t()],
          optional(:incoming) => boolean()
        }
  @type context :: %{
          optional(:data) => term(),
          optional(:recipient) => map(),
          optional(:steps) => %{String.t() => map()},
          optional(:event_time) => DateTime.t() | nil,
          optional(:run_started_at) => DateTime.t() | nil,
          optional(:incoming) => term()
        }

  @doc "The operators of the language."
  @spec operators() :: [String.t()]
  def operators, do: @operators

  @doc "The step results a condition can read."
  @spec results() :: [String.t()]
  def results, do: @results

  # WF-60
  # WF-10
  @doc "Checks a condition against its scope: the declared recipient attributes (name to type), the keys of the steps it may read (the earlier steps on its own path) and whether `incoming.…` is allowed (a `match` condition). Returns the field errors with pointers relative to the condition."
  @spec validate(term(), scope()) :: [field_error()]
  def validate(condition, scope) do
    scope = %{scope | steps: MapSet.new(scope.steps)}

    cond do
      byte_size(IO.iodata_to_binary(Relay.Workflow.Definition.canonical_json(condition))) >
          @max_bytes ->
        [error("", "too_long", "a condition is at most #{@max_bytes} bytes of canonical JSON")]

      nodes(condition) > @max_nodes ->
        [error("", "too_long", "a condition has at most #{@max_nodes} nodes")]

      depth(condition) > @max_depth ->
        [error("", "too_long", "a condition nests at most #{@max_depth} levels")]

      true ->
        check(condition, "", scope)
    end
  end

  defp check(%{} = node, pointer, scope) when map_size(node) == 1 do
    [{op, args}] = Map.to_list(node)
    check_op(op, args, pointer <> "/" <> op, scope)
  end

  defp check(_node, pointer, _scope),
    do: [error(pointer, "invalid_format", "a condition is an object with one operator")]

  defp check_op(op, [left, right], pointer, scope) when op in @binary,
    do: operand(left, pointer <> "/0", scope) ++ operand(right, pointer <> "/1", scope)

  defp check_op(op, _args, pointer, _scope) when op in @binary,
    do: [error(pointer, "invalid_format", "#{op} takes two operands")]

  defp check_op(op, [_ | _] = list, pointer, scope) when op in @logical do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> check(item, pointer <> "/#{index}", scope) end)
  end

  defp check_op(op, _args, pointer, _scope) when op in @logical,
    do: [error(pointer, "invalid_format", "#{op} takes a non-empty list of conditions")]

  defp check_op("not", condition, pointer, scope), do: check(condition, pointer, scope)

  defp check_op("exists", %{"var" => _path} = var, pointer, scope),
    do: operand(var, pointer, scope)

  defp check_op("exists", _args, pointer, _scope),
    do: [error(pointer, "invalid_format", "exists takes one variable")]

  defp check_op(op, _args, pointer, _scope),
    do: [error(pointer, "unsupported_value", "#{op} is not an operator")]

  defp operand(%{"var" => path} = var, pointer, scope) when map_size(var) == 1,
    do: path(path, pointer <> "/var", scope)

  defp operand(%{"time_add" => [time, duration]} = node, pointer, scope)
       when map_size(node) == 1 do
    pointer = pointer <> "/time_add"

    errors =
      case Relay.Workflow.Duration.seconds(duration) do
        {:ok, _seconds} ->
          []

        :error ->
          [error(pointer <> "/1", "invalid_format", "not a fixed-length ISO 8601 duration")]
      end

    operand(time, pointer <> "/0", scope) ++ errors
  end

  defp operand(%{} = node, pointer, _scope) do
    name = node |> Map.keys() |> Enum.join(",")
    [error(pointer, "unsupported_value", "#{name} is not an operand")]
  end

  defp operand(list, pointer, _scope) when is_list(list) do
    cond do
      length(list) > @max_list ->
        [error(pointer, "too_long", "a constant list has at most #{@max_list} items")]

      Enum.all?(list, &scalar?/1) ->
        list
        |> Enum.with_index()
        |> Enum.flat_map(fn {item, index} -> constant(item, pointer <> "/#{index}") end)

      true ->
        [error(pointer, "invalid_format", "a constant list holds only scalars")]
    end
  end

  defp operand(value, pointer, _scope), do: constant(value, pointer)

  defp constant(value, pointer) when is_binary(value) do
    if byte_size(value) > @max_string,
      do: [error(pointer, "too_long", "a constant string is at most #{@max_string} bytes")],
      else: []
  end

  defp constant(_value, _pointer), do: []

  defp scalar?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp path(path, pointer, scope) when is_binary(path) do
    case String.split(path, ".") do
      ["data" | [_ | _] = rest] -> segments(rest, pointer)
      ["incoming" | [_ | _] = rest] -> incoming(rest, pointer, scope)
      ["recipient", name] -> attribute(name, pointer, scope)
      ["steps", key, result] -> step(key, result, pointer, scope)
      ["event", "time"] -> []
      ["run", "started_at"] -> []
      _other -> [error(pointer, "unsupported_value", "#{path} is not a condition path")]
    end
  end

  defp path(_path, pointer, _scope),
    do: [error(pointer, "invalid_format", "a variable path is a string")]

  defp segments(rest, pointer) do
    if Enum.all?(rest, &Regex.match?(@segment, &1)),
      do: [],
      else: [error(pointer, "invalid_format", "a path segment is letters, digits, _ or -")]
  end

  defp incoming(rest, pointer, %{incoming: true}), do: segments(rest, pointer)

  defp incoming(_rest, pointer, _scope),
    do: [error(pointer, "not_allowed", "incoming is read only by a match condition")]

  defp attribute(name, pointer, scope) do
    if Map.has_key?(scope.attributes, name),
      do: [],
      else: [
        error(pointer, "not_found", "recipient.#{name} is not a declared recipient attribute")
      ]
  end

  defp step(key, result, pointer, scope) do
    cond do
      result not in @results ->
        [error(pointer, "unsupported_value", "#{result} is not a step result")]

      MapSet.member?(scope.steps, key) ->
        []

      true ->
        [error(pointer, "not_allowed", "step #{key} does not run before this condition")]
    end
  end

  defp nodes(%{"var" => _path} = node) when map_size(node) == 1, do: 1

  defp nodes(%{} = node), do: 1 + (node |> Map.values() |> Enum.map(&nodes/1) |> Enum.sum())

  defp nodes(list) when is_list(list) do
    if Enum.all?(list, &scalar?/1), do: 1, else: list |> Enum.map(&nodes/1) |> Enum.sum()
  end

  defp nodes(_scalar), do: 1

  defp depth(%{"var" => _path} = node) when map_size(node) == 1, do: 1

  defp depth(%{} = node),
    do: 1 + (node |> Map.values() |> Enum.map(&depth/1) |> Enum.max(fn -> 0 end))

  defp depth(list) when is_list(list) do
    if Enum.all?(list, &scalar?/1),
      do: 1,
      else: list |> Enum.map(&depth/1) |> Enum.max(fn -> 0 end)
  end

  defp depth(_scalar), do: 1

  # WF-60
  @doc "The `steps.<key>` keys and `recipient.<attribute>` names a condition reads, as `{:step, key}` and `{:recipient, name}`."
  @spec references(term()) :: [{:step, String.t()} | {:recipient, String.t()}]
  def references(condition) do
    condition
    |> vars([])
    |> Enum.flat_map(fn path ->
      case String.split(path, ".") do
        ["steps", key, _result] -> [{:step, key}]
        ["recipient", name] -> [{:recipient, name}]
        _other -> []
      end
    end)
    |> Enum.uniq()
  end

  defp vars(%{"var" => path}, acc) when is_binary(path), do: [path | acc]
  defp vars(%{} = node, acc), do: node |> Map.values() |> Enum.reduce(acc, &vars/2)
  defp vars(list, acc) when is_list(list), do: Enum.reduce(list, acc, &vars/2)
  defp vars(_value, acc), do: acc

  # WF-60
  # AG-14
  @doc "Decides a valid condition against a context; a type mismatch or a missing path never raises."
  @spec evaluate(t(), context()) :: boolean()
  def evaluate(%{} = condition, context) when map_size(condition) == 1 do
    [{op, args}] = Map.to_list(condition)
    decide(op, args, context)
  end

  def evaluate(_condition, _context), do: false

  defp decide("all", list, ctx) when is_list(list), do: Enum.all?(list, &evaluate(&1, ctx))
  defp decide("any", list, ctx) when is_list(list), do: Enum.any?(list, &evaluate(&1, ctx))
  defp decide("not", condition, ctx), do: not evaluate(condition, ctx)
  defp decide("exists", var, ctx), do: value(var, ctx) != nil

  defp decide(op, [left, right], ctx) when op in @binary,
    do: compare(op, value(left, ctx), value(right, ctx))

  defp decide(_op, _args, _ctx), do: false

  defp compare("eq", a, b), do: equal?(a, b)
  defp compare("ne", a, b), do: kind(a) == kind(b) and a != nil and not equal?(a, b)
  defp compare("lt", a, b), do: order(a, b) == :lt
  defp compare("lte", a, b), do: order(a, b) in [:lt, :eq]
  defp compare("gt", a, b), do: order(a, b) == :gt
  defp compare("gte", a, b), do: order(a, b) in [:gt, :eq]
  defp compare("in", a, b) when is_list(b), do: Enum.any?(b, &equal?(a, &1))
  defp compare("not_in", a, b) when is_list(b) and a != nil, do: not Enum.any?(b, &equal?(a, &1))

  defp compare("contains", a, b) when is_binary(a) and is_binary(b),
    do: String.contains?(a, b)

  defp compare("contains", a, b) when is_list(a), do: Enum.any?(a, &equal?(&1, b))

  defp compare("starts_with", a, b) when is_binary(a) and is_binary(b),
    do: String.starts_with?(a, b)

  defp compare("ends_with", a, b) when is_binary(a) and is_binary(b),
    do: String.ends_with?(a, b)

  defp compare(_op, _a, _b), do: false

  defp equal?({:time, a}, {:time, b}), do: DateTime.compare(a, b) == :eq
  defp equal?(a, b), do: kind(a) == kind(b) and a == b

  defp order({:time, a}, {:time, b}), do: DateTime.compare(a, b)

  defp order(a, b) when is_number(a) and is_number(b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  defp order(a, b) when is_binary(a) and is_binary(b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  defp order(_a, _b), do: :none

  defp kind(nil), do: :null
  defp kind(value) when is_boolean(value), do: :boolean
  defp kind(value) when is_number(value), do: :number
  defp kind(value) when is_binary(value), do: :string
  defp kind({:time, _at}), do: :time
  defp kind(value) when is_list(value), do: :list
  defp kind(_value), do: :object

  defp value(%{"var" => path}, ctx) when is_binary(path), do: lookup(String.split(path, "."), ctx)

  defp value(%{"time_add" => [time, duration]}, ctx) do
    with {:time, at} <- timestamp(value(time, ctx)),
         {:ok, seconds} <- Relay.Workflow.Duration.seconds(duration) do
      {:time, DateTime.add(at, seconds, :second)}
    else
      _missing -> nil
    end
  end

  defp value(%{} = _object, _ctx), do: nil
  defp value(constant, _ctx), do: constant

  defp timestamp({:time, _at} = time), do: time

  defp timestamp(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:time, at}
      {:error, _reason} -> nil
    end
  end

  defp timestamp(_value), do: nil

  defp lookup(["data" | rest], ctx), do: dig(Map.get(ctx, :data), rest)
  defp lookup(["incoming" | rest], ctx), do: dig(Map.get(ctx, :incoming), rest)

  defp lookup(["recipient", name], ctx),
    do: ctx |> Map.get(:recipient, %{}) |> Map.get(name) |> typed()

  defp lookup(["steps", key, result], ctx) do
    case ctx |> Map.get(:steps, %{}) |> Map.get(key) do
      %{} = results -> Map.get(results, result)
      _missing -> nil
    end
  end

  defp lookup(["event", "time"], ctx), do: typed(Map.get(ctx, :event_time))
  defp lookup(["run", "started_at"], ctx), do: typed(Map.get(ctx, :run_started_at))
  defp lookup(_path, _ctx), do: nil

  defp typed(%DateTime{} = at), do: {:time, at}
  defp typed(value) when is_map(value), do: nil
  defp typed(value), do: value

  defp dig(value, []), do: plain(value)
  defp dig(%{} = map, [key | rest]), do: dig(Map.get(map, key), rest)

  defp dig(list, [index | rest]) when is_list(list) do
    case Integer.parse(index) do
      {n, ""} when n >= 0 -> dig(Enum.at(list, n), rest)
      _other -> nil
    end
  end

  defp dig(_value, _rest), do: nil

  defp plain(value) when is_map(value), do: nil
  defp plain(value), do: value

  defp error(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}
end
