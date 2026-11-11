defmodule Relay.Workflow.Definition do
  @moduledoc """
  A workflow definition is data (C-40, INV-48, WF-5): the one format of `contracts/workflow/definition.schema.json` (WF-59) that the visual editor, the file format and the SDK produce. It carries a name, a tenant category, a fixed message class, the JSON Schema 2020-12 of its event data, the recipient attributes its conditions may read, the step tree, overrides, content deduplication and the control fields of a code-managed workflow. Nothing in it is code that runs at send time. The digest of a definition is SHA-256 over its canonical JSON (keys sorted, no insignificant whitespace), because event schemas may carry numbers that have no deterministic CBOR form.

  The publication gate (`gate/1`) checks, with RFC 6901 field errors under `/definition`:

  * the definition against the contract schema; the event schema builds as JSON Schema 2020-12 without remote references;
  * the step tree: at most 50 steps over the whole tree, branches nested at most 4 deep, step keys unique over the whole tree, and every inline route tree through `Relay.Workflow.RouteTree.validate/2` (shapes, durations above zero, depth and leaves, the subtype's channel rule; WF-13, WF-15, WF-18, WF-59 (4));
  * the hard duration ceilings (WF-37): a delay at most P90D, digest windows and throttle windows at most P31D, a wait for an event at most P30D and more than zero, a content deduplication window from PT1M to PT24H;
  * every condition (WF-60, `Relay.Workflow.Condition`): its grammar and limits, declared recipient attributes, and references only to steps that run before it on its own path, never to a later step or one in another branch;
  * a digest step is refused for the `security`, `transactional` and `action_required` classes (WF-28), and a `security` workflow has no delay, time window or digest step (WF-63, WF-41, WF-40); a `digest_template` needs an earlier digest step on its path, a time window's start comes before its end, and every control pointer names a text, duration or number field (WF-4);
  * a definition that declares the security subtype it serves: `otp_oob` sends no e-mail, neither as a channel nor in an inline route (WF-18); `email_verification` sends only e-mail. The routes a step names by key are checked against the stored routes by `named_route_errors/2` when the gate runs (existence, and the subtype's channel rule).
  """

  alias Relay.Workflow.Condition
  alias Relay.Workflow.Duration
  alias Relay.Workflow.RouteTree

  @dialect "https://json-schema.org/draft/2020-12/schema"
  @contract Path.expand("../../../contracts/workflow/definition.schema.json", __DIR__)
  @external_resource @contract
  @contract_schema @contract |> File.read!() |> Jason.decode!()

  @limits Relay.Limits.fetch!(["workflow"])
  @max_steps @limits["max_steps"]
  @max_branch_depth @limits["max_branch_depth"]
  @delay_max Relay.Limits.seconds!(["workflow", "delay_max"])
  @digest_max Relay.Limits.seconds!(["digest", "max_window"])
  @throttle_max Relay.Limits.seconds!(["throttle", "max_window"])
  @wait_max Relay.Limits.seconds!(["workflow", "wait_for_event_max"])
  @dedup_min Relay.Limits.seconds!(["content_dedup", "min_window"])
  @dedup_max Relay.Limits.seconds!(["content_dedup", "max_window"])
  @untimed ~w(delay time_window digest)
  @undigested ~w(security transactional action_required)
  @structural ~w(type key)

  @type t :: %{String.t() => term()}
  @type field_error :: %{pointer: String.t(), code: String.t(), detail: String.t()}
  @type entry :: %{
          step: map(),
          pointer: String.t(),
          depth: non_neg_integer(),
          earlier: [{String.t(), String.t()}]
        }

  # TN-65 (3)
  # WF-5
  @doc "The SHA-256 digest of a definition's canonical JSON."
  @spec digest(t()) :: <<_::256>>
  def digest(definition), do: :crypto.hash(:sha256, canonical_json(definition))

  @doc "Encodes a JSON value with its object keys sorted, so the same value has one encoding."
  @spec canonical_json(term()) :: iodata()
  def canonical_json(value), do: Jason.encode_to_iodata!(order(value))

  defp order(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, order(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp order(list) when is_list(list), do: Enum.map(list, &order/1)
  defp order(value), do: value

  # WF-1
  # API-27
  @doc "Builds the validator of a definition's event schema; a remote reference or another dialect is refused."
  @spec event_schema(map()) :: {:ok, JSV.Root.t()} | {:error, String.t()}
  def event_schema(%{} = schema) do
    cond do
      Map.get(schema, "$schema", @dialect) != @dialect ->
        {:error, "the event schema must be JSON Schema 2020-12"}

      remote_ref?(schema) ->
        {:error, "the event schema may only reference itself"}

      true ->
        case JSV.build(schema, default_meta: @dialect) do
          {:ok, root} -> {:ok, root}
          {:error, _reason} -> {:error, "the event schema is not a valid JSON Schema 2020-12"}
        end
    end
  end

  def event_schema(_schema), do: {:error, "the event schema must be an object"}

  defp remote_ref?(map) when is_map(map) do
    Enum.any?(map, fn
      {"$ref", ref} when is_binary(ref) -> not String.starts_with?(ref, "#")
      {"$dynamicRef", ref} when is_binary(ref) -> not String.starts_with?(ref, "#")
      {_key, value} -> remote_ref?(value)
    end)
  end

  defp remote_ref?(list) when is_list(list), do: Enum.any?(list, &remote_ref?/1)
  defp remote_ref?(_value), do: false

  # WF-59
  @doc "The contract schema of the definition format, as decoded JSON."
  @spec contract() :: map()
  def contract, do: @contract_schema

  # WF-59
  @doc "Validates a definition against the contract schema; field errors under `/definition`."
  @spec contract_errors(term()) :: [field_error()]
  def contract_errors(definition) do
    case JSV.validate(definition, JSV.build!(@contract_schema, default_meta: @dialect),
           cast: false
         ) do
      {:ok, _value} ->
        []

      {:error, error} ->
        error
        |> JSV.normalize_error(min_error_level: JSV.ErrorFormatter.level_cause())
        |> Map.fetch!(:details)
        |> Enum.flat_map(&unit/1)
        |> Enum.uniq_by(&{&1.pointer, &1.code})
        |> Enum.sort_by(& &1.pointer)
    end
  end

  defp unit(%{instanceLocation: location} = unit) do
    pointer = "/definition" <> String.trim_leading(location, "#")

    for %{kind: kind, message: message} <- Map.get(unit, :errors, []),
        do: error(pointer, code(kind), message)
  end

  defp code(:required), do: "required"
  defp code(:additionalProperties), do: "not_allowed"
  defp code(kind) when kind in [:maxLength, :maxItems, :maxProperties, :maximum], do: "too_long"
  defp code(kind) when kind in [:minLength, :minItems, :minProperties, :minimum], do: "too_short"
  defp code(kind) when kind in [:enum, :const], do: "unsupported_value"
  defp code(:uniqueItems), do: "conflict"
  defp code(_kind), do: "invalid_format"

  # WF-1
  # WF-8
  # WF-59
  # WF-60
  # API-24
  @doc "Runs the publication gate over a definition and returns its field errors; none means it may be published."
  @spec gate(t()) :: [field_error()]
  def gate(definition) do
    case contract_errors(definition) do
      [] -> schema_errors(definition) ++ tree_errors(definition)
      errors -> errors
    end
  end

  defp schema_errors(definition) do
    case event_schema(Map.get(definition, "event_schema")) do
      {:ok, _root} -> []
      {:error, detail} -> [error("/definition/event_schema", "invalid_format", detail)]
    end
  end

  defp tree_errors(definition) do
    entries = entries(definition)

    size_errors(entries) ++
      key_errors(entries) ++
      Enum.flat_map(entries, &step_errors(&1, definition)) ++
      dedup_errors(definition) ++
      control_errors(definition) ++
      security_errors(definition, entries) ++
      subtype_errors(definition, entries)
  end

  # WF-59
  @doc "Every step of the tree in order, with its pointer, its branch depth and the earlier steps on its path as `{key, type}`."
  @spec entries(t()) :: [entry()]
  def entries(definition) do
    definition
    |> Map.get("steps", [])
    |> walk("/definition/steps", 0, [])
  end

  defp walk(steps, pointer, depth, earlier) when is_list(steps) do
    steps
    |> Enum.with_index()
    |> Enum.reduce({[], earlier}, fn {step, index}, {acc, seen} ->
      at = pointer <> "/#{index}"
      entry = %{step: step, pointer: at, depth: depth, earlier: seen}
      inner = [{step["key"], step["type"]} | seen]
      {acc ++ [entry | children(step, at, depth + 1, inner)], inner}
    end)
    |> elem(0)
  end

  defp walk(_steps, _pointer, _depth, _earlier), do: []

  defp children(%{"type" => "condition"} = step, at, depth, earlier) do
    branches =
      step
      |> Map.get("branches", [])
      |> Enum.with_index()
      |> Enum.flat_map(fn {branch, index} ->
        walk(branch["steps"] || [], at <> "/branches/#{index}/steps", depth, earlier)
      end)

    branches ++ walk(step["else"] || [], at <> "/else", depth, earlier)
  end

  defp children(%{"type" => "wait_for_event"} = step, at, depth, earlier),
    do: walk(step["on_timeout"] || [], at <> "/on_timeout", depth, earlier)

  defp children(_step, _at, _depth, _earlier), do: []

  defp size_errors(entries) do
    total =
      if length(entries) > @max_steps,
        do: [error("/definition/steps", "too_long", "at most #{@max_steps} steps in the tree")],
        else: []

    deep =
      for %{depth: depth, pointer: pointer} <- entries,
          depth > @max_branch_depth,
          do: error(pointer, "too_long", "branches are nested at most #{@max_branch_depth} deep")

    total ++ Enum.take(deep, 1)
  end

  defp key_errors(entries) do
    entries
    |> Enum.reduce({MapSet.new(), []}, fn %{step: step, pointer: pointer}, {seen, errors} ->
      key = step["key"]

      if MapSet.member?(seen, key),
        do: {seen, [error(pointer <> "/key", "conflict", "step keys are unique") | errors]},
        else: {MapSet.put(seen, key), errors}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp step_errors(%{step: %{"type" => "channel"} = step} = entry, definition) do
    Enum.concat([
      route_errors(step["route"], entry.pointer <> "/route", definition),
      digest_template_errors(step, entry),
      variant_errors(step, entry.pointer)
    ])
  end

  defp step_errors(%{step: %{"type" => "delay"} = step, pointer: pointer}, _definition),
    do: max_errors(step["duration"], pointer <> "/duration", @delay_max, "P90D")

  defp step_errors(%{step: %{"type" => "digest"} = step, pointer: pointer}, definition) do
    class =
      if definition["message_class"] in @undigested,
        do: [
          error(
            pointer,
            "not_allowed",
            "the #{definition["message_class"]} class is not digested"
          )
        ],
        else: []

    windows =
      Enum.flat_map(~w(debounce max_wait), fn field ->
        max_errors(step[field], pointer <> "/" <> field, @digest_max, "P31D")
      end)

    class ++ windows
  end

  defp step_errors(%{step: %{"type" => "throttle"} = step, pointer: pointer}, _definition),
    do: max_errors(step["window"], pointer <> "/window", @throttle_max, "P31D")

  defp step_errors(%{step: %{"type" => "condition"} = step} = entry, definition) do
    scope = condition_scope(entry, definition, false)

    step
    |> Map.get("branches", [])
    |> Enum.with_index()
    |> Enum.flat_map(fn {branch, index} ->
      at = entry.pointer <> "/branches/#{index}/when"
      prefix(Condition.validate(branch["when"], scope), at)
    end)
  end

  defp step_errors(%{step: %{"type" => "wait_for_event"} = step} = entry, definition) do
    timeout = max_errors(step["timeout"], entry.pointer <> "/timeout", @wait_max, "P30D")

    match =
      case step["match"] do
        nil ->
          []

        condition ->
          scope = condition_scope(entry, definition, true)
          prefix(Condition.validate(condition, scope), entry.pointer <> "/match")
      end

    timeout ++ match
  end

  defp step_errors(%{step: %{"type" => "time_window"} = step, pointer: pointer}, _definition) do
    for {window, index} <- Enum.with_index(step["windows"] || []),
        window["start"] >= window["end"],
        do:
          error(
            pointer <> "/windows/#{index}/end",
            "invalid_format",
            "a window ends after it starts"
          )
  end

  defp step_errors(_entry, _definition), do: []

  # WF-63
  # WF-41
  # WF-40
  defp security_errors(%{"message_class" => "security"}, entries) do
    for %{step: %{"type" => type}, pointer: pointer} <- entries,
        type in @untimed,
        do:
          error(
            pointer,
            "not_allowed",
            "a security workflow is never delayed, windowed or digested"
          )
  end

  defp security_errors(_definition, _entries), do: []

  defp condition_scope(entry, definition, incoming?) do
    %{
      attributes: definition["recipient_attributes"] || %{},
      steps: Enum.map(entry.earlier, &elem(&1, 0)),
      incoming: incoming?
    }
  end

  defp prefix(errors, at), do: Enum.map(errors, &%{&1 | pointer: at <> &1.pointer})

  defp max_errors(nil, _pointer, _max, _text), do: []

  defp max_errors(duration, pointer, max, text) do
    case Duration.seconds(duration) do
      {:ok, 0} -> [error(pointer, "too_short", "the duration is more than zero")]
      {:ok, seconds} when seconds > max -> [error(pointer, "too_long", "at most #{text}")]
      {:ok, _seconds} -> []
      :error -> [error(pointer, "invalid_format", "not a fixed-length ISO 8601 duration")]
    end
  end

  # WF-13
  # WF-15
  # WF-18
  # WF-59 (4)
  defp route_errors(%{} = tree, pointer, definition) do
    case RouteTree.validate(tree,
           pointer: pointer,
           security_subtype: definition["security_subtype"]
         ) do
      :ok -> []
      {:error, errors} -> errors
    end
  end

  defp route_errors(_key_or_none, _pointer, _definition), do: []

  defp digest_template_errors(%{"digest_template" => _template}, entry) do
    if Enum.any?(entry.earlier, &(elem(&1, 1) == "digest")),
      do: [],
      else: [
        error(
          entry.pointer <> "/digest_template",
          "not_allowed",
          "a digest template needs an earlier digest step"
        )
      ]
  end

  defp digest_template_errors(_step, _entry), do: []

  defp variant_errors(%{"variants" => variants}, pointer) when is_list(variants) do
    keys = Enum.map(variants, & &1["key"])

    keys
    |> Enum.with_index()
    |> Enum.filter(fn {key, index} -> key in Enum.take(keys, index) end)
    |> Enum.map(fn {_key, index} ->
      error(pointer <> "/variants/#{index}/key", "conflict", "variant keys are unique")
    end)
  end

  defp variant_errors(_step, _pointer), do: []

  # WF-35
  defp dedup_errors(%{"content_dedup" => %{"window" => window}}) do
    pointer = "/definition/content_dedup/window"

    case Duration.seconds(window) do
      {:ok, seconds} when seconds < @dedup_min -> [error(pointer, "too_short", "at least PT1M")]
      {:ok, seconds} when seconds > @dedup_max -> [error(pointer, "too_long", "at most PT24H")]
      {:ok, _seconds} -> []
      :error -> [error(pointer, "invalid_format", "not a fixed-length ISO 8601 duration")]
    end
  end

  defp dedup_errors(_definition), do: []

  # WF-4
  defp control_errors(%{"controls" => controls} = definition) when is_list(controls) do
    controls
    |> Enum.with_index()
    |> Enum.flat_map(fn {pointer, index} ->
      at = "/definition/controls/#{index}"

      case control(definition, pointer) do
        :ok -> []
        {:error, detail} -> [error(at, "not_allowed", detail)]
      end
    end)
  end

  defp control_errors(_definition), do: []

  # WF-4
  @doc "Whether an RFC 6901 pointer names a control field of a definition: a text, duration or number value that is not a step's type or key, and not under the event schema."
  @spec control(t(), String.t()) :: :ok | {:error, String.t()}
  def control(definition, pointer) do
    segments = pointer |> String.split("/") |> tl() |> Enum.map(&unescape/1)

    cond do
      List.last(segments) in @structural ->
        {:error, "a step's type and key are structure"}

      hd(segments) in ["event_schema", "controls"] ->
        {:error, "the event schema and the controls are structure"}

      true ->
        case get(definition, segments) do
          {:ok, value} when is_binary(value) or is_number(value) -> :ok
          {:ok, _value} -> {:error, "only text, duration and number fields are controls"}
          :error -> {:error, "the pointer names no field"}
        end
    end
  end

  # WF-4
  @doc "Reads the value at RFC 6901 segments of a document."
  @spec get(term(), [String.t()]) :: {:ok, term()} | :error
  def get(value, []), do: {:ok, value}

  def get(%{} = map, [key | rest]) do
    case Map.fetch(map, key) do
      {:ok, value} -> get(value, rest)
      :error -> :error
    end
  end

  def get(list, [index | rest]) when is_list(list) do
    case Integer.parse(index) do
      {n, ""} when n >= 0 and n < length(list) -> get(Enum.at(list, n), rest)
      _other -> :error
    end
  end

  def get(_value, _segments), do: :error

  defp unescape(segment), do: segment |> String.replace("~1", "/") |> String.replace("~0", "~")

  # WF-18
  # WF-40
  defp subtype_errors(%{"security_subtype" => subtype} = definition, entries) do
    class =
      if definition["message_class"] == "security",
        do: [],
        else: [
          error(
            "/definition/security_subtype",
            "not_allowed",
            "only the security class has subtypes"
          )
        ]

    class ++ Enum.flat_map(entries, &subtype_step_errors(&1, subtype))
  end

  defp subtype_errors(_definition, _entries), do: []

  defp subtype_step_errors(%{step: %{"type" => "channel"} = step, pointer: pointer}, subtype),
    do: channel_subtype_errors(step_channels(step), subtype, pointer)

  defp subtype_step_errors(_entry, _subtype), do: []

  defp step_channels(%{"channel" => channel}), do: [channel]
  defp step_channels(%{"route" => %{} = tree}), do: RouteTree.channels(tree)
  defp step_channels(_step), do: []

  defp channel_subtype_errors(channels, "otp_oob", pointer) do
    if "email" in channels,
      do: [error(pointer, "not_allowed", "an otp_oob route never sends e-mail")],
      else: []
  end

  defp channel_subtype_errors(channels, "email_verification", pointer) do
    if Enum.all?(channels, &(&1 == "email")),
      do: [],
      else: [error(pointer, "not_allowed", "email_verification sends only e-mail")]
  end

  defp channel_subtype_errors(_channels, _subtype, _pointer), do: []

  # WF-18
  @doc "The field errors of the named routes a definition's channel steps use, given each route key's reachable channels (`nil` for an unknown key): an unknown key is `not_found`, and an `otp_oob` definition's route must not reach e-mail."
  @spec named_route_errors(t(), %{String.t() => [String.t()] | nil}) :: [field_error()]
  def named_route_errors(definition, routes) do
    for %{step: %{"type" => "channel", "route" => key}, pointer: pointer} <- entries(definition),
        is_binary(key),
        found <- [Map.get(routes, key)],
        error <- named_route(found, definition["security_subtype"], pointer <> "/route"),
        do: error
  end

  defp named_route(nil, _subtype, pointer),
    do: [error(pointer, "not_found", "no route has this key")]

  defp named_route(channels, subtype, pointer),
    do: channel_subtype_errors(channels, subtype, String.replace_suffix(pointer, "/route", ""))

  defp error(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}

  # WF-8
  # WF-59
  @doc "The channel steps of the whole step tree in order as `{key, channel, template}`, one entry per channel of a step's `channel` or inline route tree; a step that names a route key is left out (its tree is read from the route store, `Relay.Workflow.route_steps/2`)."
  @spec steps(t()) :: [%{key: String.t(), channel: String.t(), template: String.t()}]
  def steps(definition) do
    for %{step: %{"type" => "channel"} = step} <- entries(definition),
        tree <- inline(step),
        channel <- RouteTree.channels(tree),
        do: %{key: step["key"], channel: channel, template: step["template"]}
  end

  defp inline(%{"route" => %{} = tree}), do: [tree]
  defp inline(%{"route" => _key}), do: []
  defp inline(%{"channel" => channel}) when is_binary(channel), do: [channel]
  defp inline(_step), do: []

  # WF-6
  @doc "The definition as a Mermaid flowchart: one node per step, a condition's branches and else and a wait's timeout as labelled edges, and every branch joining the step after its branching step."
  @spec mermaid(t()) :: String.t()
  def mermaid(definition) do
    {lines, exits} = chart(Map.get(definition, "steps", []), [{"start", nil}], [])

    IO.iodata_to_binary([
      "flowchart TD\n",
      "  start([start])\n",
      Enum.map(Enum.reverse(edges(exits, "finish", lines)), &[&1, "\n"]),
      "  finish([end])\n"
    ])
  end

  defp chart(steps, from, lines) do
    Enum.reduce(steps, {lines, from}, fn step, {acc, previous} ->
      id = node_id(step)
      exits(step, id, edges(previous, id, [node_line(step) | acc]))
    end)
  end

  defp edges(from, id, acc) do
    Enum.reduce(from, acc, fn
      {source, nil}, acc -> ["  #{source} --> #{id}" | acc]
      {source, label}, acc -> ["  #{source} -->|#{label}| #{id}" | acc]
    end)
  end

  defp exits(%{"type" => "condition"} = step, id, acc) do
    branches =
      step
      |> Map.get("branches", [])
      |> Enum.with_index(1)
      |> Enum.map(fn {branch, index} -> {branch["steps"] || [], "branch #{index}"} end)

    Enum.reduce(branches ++ [{step["else"] || [], "else"}], {acc, []}, fn {steps, label},
                                                                          {acc, out} ->
      {acc, tail} = chart(steps, [{id, label}], acc)
      {acc, out ++ tail}
    end)
  end

  defp exits(%{"type" => "wait_for_event"} = step, id, acc) do
    {acc, tail} = chart(step["on_timeout"] || [], [{id, "timeout"}], acc)
    {acc, [{id, "event"} | tail]}
  end

  defp exits(_step, id, acc), do: {acc, [{id, nil}]}

  defp node_id(step), do: "s_" <> to_string(step["key"])

  defp node_line(step) do
    text = "#{step["type"]}: #{step["key"]}#{detail(step)}" |> String.replace(~s("), "'")

    case step["type"] do
      "condition" ->
        ~s(  #{node_id(step)}{"#{text}"})

      type when type in ~w(delay time_window wait_for_event digest throttle) ->
        ~s(  #{node_id(step)}[/"#{text}"/])

      _channel ->
        ~s(  #{node_id(step)}["#{text}"])
    end
  end

  defp detail(%{"type" => "channel", "channel" => channel}), do: " (#{channel})"
  defp detail(%{"type" => "channel", "route" => key}) when is_binary(key), do: " (route #{key})"
  defp detail(%{"type" => "channel"}), do: " (route)"
  defp detail(%{"type" => "delay", "duration" => duration}), do: " (#{duration})"
  defp detail(%{"type" => "delay", "until" => until}), do: " (until #{until})"
  defp detail(%{"type" => "wait_for_event", "event_type" => type}), do: " (#{type})"
  defp detail(_step), do: ""
end
