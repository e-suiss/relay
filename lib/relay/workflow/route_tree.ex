defmodule Relay.Workflow.RouteTree do
  @moduledoc """
  The route tree as pure data (WF-13, WF-59 (4)): its validation and the evaluator that turns a tree, the recipient's channel facts and the results so far into the next actions. Nothing here reads the database or the clock; the caller passes `now`.

  A node is one of:

    * a channel name;
    * `{"channel": c, "strategy": "last_active_device"}`: push only to the recipient's last active device (WF-17);
    * `{"single": [node], "trigger": "on_failure" | {"after_delay": duration}}`: try in order and stop at the first success (WF-15);
    * `{"all": [node]}`: send to every node;
    * `{"last_active": [channel]}` and `{"user_preference": [channel]}`: send to one channel of the list (WF-13);
    * `{"escalate": {"unless": "seen" | "read" | "clicked" | "event", "event_type": type, "ladder": [{"after": duration, "node": node}]}}`: escalate unless the recipient engages (WF-21).

  Depth and leaf count are bounded by `x-relay-limits.route`. Every leaf has a stable address, its RFC 6901 pointer inside the tree: `""` for a lone channel, `/single/1/all/0`, `/escalate/ladder/0/node`, `/last_active/1`. The results the caller passes and the actions it gets back are keyed by it.

  Semantics of `next/3`:

    * A leaf that has not been opened is checked before it opens: the channel rule of the security subtype (WF-18, PC-51), the template variant (WF-16, `template.variant_missing`), the gate of a locked category (PC-10, `route.channel_locked`) and an address on the channel (`channel.no_address`). A leaf that fails a check is skipped with its rule and counts as failed, so a `single` moves on in the same evaluation.
    * `single` with `on_failure` moves to its next node only when the current one has failed: every leaf failed permanently, exhausted its retry budget or was skipped. A transient failure and an `unknown` outcome never move it (WF-15, DS-21). With `after_delay` it also moves when the current node is not delivered within the delay.
    * `all` opens every node.
    * `last_active` and `user_preference` open one channel: the recipient's last active, or most preferred, channel of the list when it can be sent, else the first one of the list that can. A skipped channel gives way to the next candidate; a permanent failure of the chosen one fails the node.
    * `escalate` opens its first step, waits that step's `after` and then opens the next step unless a stop signal came; a step that fails moves on at once. Only reliable evidence stops it (WF-22, DS-10): an in-app `seen`, `read` or `clicked`, a push SDK receipt, a human click (DS-31) or the customer's event. An e-mail open and a likely bot click never do. `seen` is also met by `read` and `clicked`, and `read` by `clicked`. The timers run whatever the delivery outcome, `unknown` included (DS-21). Once stopped, no further step opens (`escalation.stopped`).
  """

  @channels ~w(push web_push email sms voice whatsapp slack teams telegram discord in_app webhook)
  @device_channels ~w(push web_push)
  @otp_channels ~w(sms whatsapp voice)
  @unless %{"seen" => :seen, "read" => :read, "clicked" => :clicked, "event" => :event}
  @stop_signals %{seen: [:seen, :read, :clicked], read: [:read, :clicked], clicked: [:clicked]}
  @duration ~r/\AP(?!\z)(?:(\d+)W)?(?:(\d+)D)?(?:T(?=\d)(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/
  @units [604_800_000, 86_400_000, 3_600_000, 60_000, 1_000]
  @event_type ~r/\A[a-z0-9][a-z0-9_.-]{0,127}\z/
  @max_depth Relay.Limits.fetch!(["route", "max_depth"])
  @max_leaves Relay.Limits.fetch!(["route", "max_leaves"])

  @type channel :: String.t()
  @type pointer :: String.t()
  @type field_error :: %{pointer: String.t(), code: String.t(), detail: String.t()}
  @type leaf_status ::
          :pending | :transient | :unknown | :delivered | :failed | :exhausted | :skipped
  @type evidence :: %{
          required(:signal) => :seen | :read | :clicked | :opened,
          required(:decision_grade) => :reliable | :unreliable,
          optional(:actor) => :human | :likely_bot | nil
        }
  @type leaf_state :: %{
          required(:status) => leaf_status(),
          required(:at) => DateTime.t(),
          optional(:evidence) => [evidence()]
        }
  @type facts :: %{
          optional(:reachable) => [channel()] | :all,
          optional(:variants) => [channel()] | :all,
          optional(:locked) => [channel()],
          optional(:last_active_channel) => channel() | nil,
          optional(:preferred_channels) => [channel()],
          optional(:last_active_device) => String.t() | nil,
          optional(:security_subtype) => String.t() | nil
        }
  @type state :: %{
          required(:now) => DateTime.t(),
          optional(:leaves) => %{pointer() => leaf_state()},
          optional(:events) => [%{type: String.t(), at: DateTime.t()}]
        }
  @type open :: %{at: pointer(), channel: channel(), device: :all | {:device, String.t()}}
  @type skip :: %{at: pointer(), channel: channel(), rule_id: String.t()}
  @type stop :: %{at: pointer(), rule_id: String.t(), signal: atom()}
  @type plan :: %{
          status: :running | :delivered | :exhausted | :stopped,
          rule_id: String.t() | nil,
          open: [open()],
          skip: [skip()],
          stopped: [stop()],
          wake_at: DateTime.t() | nil
        }

  # WF-13
  # WF-15
  # WF-18
  # WF-59 (4)
  @doc "Validates a route tree: its node shapes, channel names, durations above zero (WF-15), depth and leaf count (WF-59 (4)) and, with `security_subtype:`, the channel rule of the subtype (WF-18). Errors are field errors whose pointers start with `pointer:` (default `\"\"`)."
  @spec validate(term(), keyword()) :: :ok | {:error, [field_error()]}
  def validate(tree, opts \\ []) do
    prefix = Keyword.get(opts, :pointer, "")

    errors =
      case parse(tree) do
        {:ok, root} -> subtype_errors(root, Keyword.get(opts, :security_subtype))
        {:error, errors} -> errors
      end

    case errors do
      [] -> :ok
      errors -> {:error, Enum.map(errors, &%{&1 | pointer: prefix <> &1.pointer})}
    end
  end

  # WF-13
  @doc "The channels a valid tree names, each once, in the order they are written; `[]` for an invalid tree."
  @spec channels(term()) :: [channel()]
  def channels(tree) do
    tree |> leaf_pointers() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
  end

  # WF-13
  @doc "The leaves of a valid tree as `{pointer, channel}` pairs in the order they are written; `[]` for an invalid tree."
  @spec leaf_pointers(term()) :: [{pointer(), channel()}]
  def leaf_pointers(tree) do
    case parse(tree) do
      {:ok, root} -> root |> leaves() |> Enum.map(&{&1.at, &1.channel})
      {:error, _errors} -> []
    end
  end

  # WF-13
  # WF-15
  # WF-16
  # WF-17
  # WF-21
  # WF-22
  # PC-10
  # DS-21
  # DS-31
  @doc "The next actions of a route: the leaves to open now (`open`), the leaves to record as skipped with their rule (`skip`), the escalations that stopped (`stopped`), the time to evaluate again (`wake_at`) and the route's status. A leaf already in `state.leaves` is never opened again, and the same tree, facts and state always give the same plan."
  @spec next(term(), facts(), state()) :: {:ok, plan()} | {:error, [field_error()]}
  def next(tree, facts, %{now: %DateTime{}} = state) do
    with {:ok, root} <- parse(tree) do
      ctx = %{
        facts: normalize(facts),
        now: state.now,
        leaves: Map.get(state, :leaves, %{}),
        events: Map.get(state, :events, [])
      }

      {status, _started, acc} = eval(root, ctx, %{open: [], skip: [], stopped: [], wake_at: nil})
      {:ok, plan(status, acc)}
    end
  end

  defp plan(status, acc) do
    route_status =
      cond do
        status == :pending or acc.wake_at != nil -> :running
        status == :failed -> :exhausted
        acc.stopped != [] -> :stopped
        true -> :delivered
      end

    %{
      status: route_status,
      rule_id: if(route_status == :exhausted, do: "route.exhausted"),
      open: Enum.reverse(acc.open),
      skip: Enum.reverse(acc.skip),
      stopped: Enum.reverse(acc.stopped),
      wake_at: acc.wake_at
    }
  end

  defp normalize(facts) do
    %{
      reachable: set(Map.get(facts, :reachable, :all)),
      variants: set(Map.get(facts, :variants, :all)),
      locked: set(Map.get(facts, :locked, [])),
      last_active_channel: Map.get(facts, :last_active_channel),
      preferred_channels: Map.get(facts, :preferred_channels, []),
      last_active_device: Map.get(facts, :last_active_device),
      security_subtype: Map.get(facts, :security_subtype)
    }
  end

  defp set(:all), do: :all
  defp set(list) when is_list(list), do: MapSet.new(list)

  defp eval(%{kind: :leaf} = node, ctx, acc) do
    case Map.fetch(ctx.leaves, node.at) do
      {:ok, leaf} -> {leaf_outcome(leaf.status), leaf.at, acc}
      :error -> activate(node, ctx, acc)
    end
  end

  defp eval(%{kind: :single} = node, ctx, acc), do: single(node.children, node, ctx, acc, [])

  defp eval(%{kind: :all} = node, ctx, acc) do
    {results, acc} =
      Enum.map_reduce(node.children, acc, fn child, acc ->
        {status, started, acc} = eval(child, ctx, acc)
        {{status, started}, acc}
      end)

    {aggregate(results), earliest(results), acc}
  end

  defp eval(%{kind: :pick} = node, ctx, acc) do
    case Enum.find(node.children, &chosen?(&1, ctx.leaves)) do
      nil -> pick(candidates(node, ctx.facts), ctx, acc)
      leaf -> eval(leaf, ctx, acc)
    end
  end

  defp eval(%{kind: :escalate} = node, ctx, acc) do
    case stop_signal(node, ctx) do
      nil ->
        ladder(node.ladder, ctx, acc, [])

      {signal, started} ->
        stop = %{at: node.at, rule_id: "escalation.stopped", signal: signal}
        {:succeeded, started, %{acc | stopped: [stop | acc.stopped]}}
    end
  end

  defp chosen?(leaf, leaves) do
    case Map.fetch(leaves, leaf.at) do
      {:ok, %{status: :skipped}} -> false
      {:ok, _leaf} -> true
      :error -> false
    end
  end

  defp leaf_outcome(:delivered), do: :succeeded
  defp leaf_outcome(status) when status in [:failed, :exhausted, :skipped], do: :failed
  defp leaf_outcome(_pending), do: :pending

  defp activate(node, ctx, acc) do
    case skip_rule(node.channel, ctx.facts) do
      nil ->
        open = %{at: node.at, channel: node.channel, device: device(node, ctx.facts)}
        {:pending, ctx.now, %{acc | open: [open | acc.open]}}

      rule_id ->
        skip = %{at: node.at, channel: node.channel, rule_id: rule_id}
        {:failed, nil, %{acc | skip: [skip | acc.skip]}}
    end
  end

  defp device(%{device: :last_active}, %{last_active_device: id}) when is_binary(id),
    do: {:device, id}

  defp device(_node, _facts), do: :all

  # WF-18
  # WF-16
  # PC-10
  defp skip_rule(channel, facts) do
    subtype = subtype_rule(facts.security_subtype, channel)

    cond do
      subtype != nil -> subtype
      not member?(facts.variants, channel) -> "template.variant_missing"
      MapSet.member?(facts.locked, channel) -> "route.channel_locked"
      not member?(facts.reachable, channel) -> "channel.no_address"
      true -> nil
    end
  end

  defp subtype_rule("otp_oob", channel) when channel not in @otp_channels,
    do: "channel_policy.otp_channel_forbidden"

  defp subtype_rule("email_verification", channel) when channel != "email",
    do: "channel_policy.email_verification_only"

  defp subtype_rule(_subtype, _channel), do: nil

  defp member?(:all, _channel), do: true
  defp member?(set, channel), do: MapSet.member?(set, channel)

  defp single([], _node, _ctx, acc, results), do: {aggregate(results), earliest(results), acc}

  defp single([child | rest], node, ctx, acc, results) do
    {status, started, acc} = eval(child, ctx, acc)
    results = [{status, started} | results]

    case {status, node.delay} do
      {:failed, _delay} -> single(rest, node, ctx, acc, results)
      {:succeeded, _delay} -> {:succeeded, earliest(results), acc}
      {:pending, nil} -> {:pending, earliest(results), acc}
      {:pending, delay} -> delayed(rest, node, ctx, acc, results, due(started, delay))
    end
  end

  defp delayed([], _node, _ctx, acc, results, _due), do: {:pending, earliest(results), acc}

  defp delayed(rest, node, ctx, acc, results, due) do
    if DateTime.compare(ctx.now, due) == :lt,
      do: {:pending, earliest(results), wake(acc, due)},
      else: single(rest, node, ctx, acc, results)
  end

  defp pick([], _ctx, acc), do: {:failed, nil, acc}

  defp pick([leaf | rest], ctx, acc) do
    case eval(leaf, ctx, acc) do
      {:failed, _started, acc} -> pick(rest, ctx, acc)
      result -> result
    end
  end

  defp candidates(%{strategy: :last_active} = node, facts),
    do: ordered(node.children, List.wrap(facts.last_active_channel))

  defp candidates(%{strategy: :user_preference} = node, facts),
    do: ordered(node.children, facts.preferred_channels)

  defp ordered(children, first) do
    preferred = for channel <- first, leaf <- children, leaf.channel == channel, do: leaf
    Enum.uniq(preferred ++ children)
  end

  defp ladder([], _ctx, acc, results), do: {aggregate(results), earliest(results), acc}

  defp ladder([{after_ms, node} | rest], ctx, acc, results) do
    {status, started, acc} = eval(node, ctx, acc)
    results = [{status, started} | results]

    if status == :failed,
      do: ladder(rest, ctx, acc, results),
      else: rung_wait(rest, ctx, acc, results, due(started, after_ms))
  end

  defp rung_wait(rest, ctx, acc, results, due) do
    if DateTime.compare(ctx.now, due) == :lt,
      do: {:pending, earliest(results), wake(acc, due)},
      else: ladder(rest, ctx, acc, results)
  end

  # WF-21
  # WF-22
  # DS-10
  # DS-31
  defp stop_signal(node, ctx) do
    prefix = node.at <> "/escalate/ladder/"
    opened = Enum.filter(ctx.leaves, fn {at, _leaf} -> String.starts_with?(at, prefix) end)

    started =
      opened
      |> Enum.map(fn {_at, leaf} -> leaf.at end)
      |> Enum.min(DateTime, &nil_fun/0)

    with %DateTime{} <- started,
         signal when signal != nil <- signal(node, ctx, opened, started),
         do: {signal, started}
  end

  defp nil_fun, do: nil

  defp signal(%{unless: :event} = node, ctx, _opened, started) do
    if Enum.any?(ctx.events, &(&1.type == node.event_type and not before?(&1.at, started))),
      do: :event
  end

  defp signal(node, _ctx, opened, _started) do
    signals = Map.fetch!(@stop_signals, node.unless)

    found =
      for {_at, leaf} <- opened,
          evidence <- Map.get(leaf, :evidence, []),
          reliable?(evidence, signals),
          do: evidence.signal

    List.first(found)
  end

  defp reliable?(evidence, signals) do
    evidence.decision_grade == :reliable and evidence.signal in signals and human?(evidence)
  end

  defp human?(%{signal: :clicked} = evidence), do: Map.get(evidence, :actor) == :human
  defp human?(evidence), do: Map.get(evidence, :actor) != :likely_bot

  defp before?(at, started), do: DateTime.compare(at, started) == :lt

  defp aggregate(results) do
    statuses = Enum.map(results, &elem(&1, 0))

    cond do
      :succeeded in statuses -> :succeeded
      :pending in statuses -> :pending
      true -> :failed
    end
  end

  defp earliest(results) do
    results
    |> Enum.map(&elem(&1, 1))
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, &nil_fun/0)
  end

  defp due(started, ms), do: DateTime.add(started, ms, :millisecond)

  defp wake(%{wake_at: nil} = acc, due), do: %{acc | wake_at: due}

  defp wake(acc, due) do
    if DateTime.compare(due, acc.wake_at) == :lt, do: %{acc | wake_at: due}, else: acc
  end

  defp leaves(%{kind: :leaf} = leaf), do: [leaf]
  defp leaves(%{kind: :escalate} = node), do: Enum.flat_map(node.ladder, &leaves(elem(&1, 1)))
  defp leaves(%{children: children}), do: Enum.flat_map(children, &leaves/1)

  # WF-18
  defp subtype_errors(root, subtype) do
    for leaf <- leaves(root),
        message = subtype_message(subtype, leaf.channel),
        do: error(leaf.at, "not_allowed", message)
  end

  defp subtype_message("otp_oob", "email"), do: "an otp_oob route never sends email"

  defp subtype_message("email_verification", channel) when channel != "email",
    do: "an email_verification route sends only email"

  defp subtype_message(_subtype, _channel), do: nil

  # WF-59 (4)
  defp parse(tree) do
    case node(tree, "", 1) do
      {root, []} -> leaf_limit(root)
      {_root, errors} -> {:error, errors}
    end
  end

  defp leaf_limit(root) do
    if length(leaves(root)) > @max_leaves,
      do: {:error, [error("", "too_long", "a route has at most #{@max_leaves} channels")]},
      else: {:ok, root}
  end

  defp node(_tree, at, depth) when depth > @max_depth,
    do: {nil, [error(at, "too_long", "a route is at most #{@max_depth} levels deep")]}

  defp node(channel, at, _depth) when is_binary(channel), do: leaf(channel, at, :all)
  defp node(%{"channel" => _channel} = map, at, _depth), do: device_leaf(map, at)
  defp node(%{"single" => _children} = map, at, depth), do: single_node(map, at, depth)
  defp node(%{"all" => children} = map, at, depth), do: all_node(map, children, at, depth)

  defp node(%{"last_active" => channels} = map, at, depth),
    do: pick_node(map, {"last_active", :last_active}, channels, at, depth)

  defp node(%{"user_preference" => channels} = map, at, depth),
    do: pick_node(map, {"user_preference", :user_preference}, channels, at, depth)

  defp node(%{"escalate" => _escalate} = map, at, depth), do: escalate_node(map, at, depth)
  defp node(_other, at, _depth), do: {nil, [shape(at)]}

  defp leaf(channel, at, device) when channel in @channels,
    do: {%{kind: :leaf, at: at, channel: channel, device: device}, []}

  defp leaf(_channel, at, _device), do: {nil, [error(at, "unsupported_value", "not a channel")]}

  # WF-17
  defp device_leaf(map, at) do
    cond do
      Map.keys(map) -- ["channel", "strategy"] != [] ->
        {nil, [shape(at)]}

      map["strategy"] != "last_active_device" ->
        {nil, [error(at <> "/strategy", "unsupported_value", "last_active_device")]}

      map["channel"] not in @device_channels ->
        {nil, [error(at <> "/channel", "not_allowed", "only push goes to one device")]}

      true ->
        leaf(map["channel"], at, :last_active)
    end
  end

  # WF-15
  defp single_node(map, at, depth) do
    with :ok <- only(map, ["single", "trigger"], at),
         {:ok, delay} <- trigger(map, at) do
      build = &%{kind: :single, at: at, children: &1, delay: delay}
      composite(map["single"], at <> "/single", depth, build)
    else
      {:error, errors} -> {nil, errors}
    end
  end

  defp all_node(map, children, at, depth) do
    case only(map, ["all"], at) do
      :ok -> composite(children, at <> "/all", depth, &%{kind: :all, at: at, children: &1})
      {:error, errors} -> {nil, errors}
    end
  end

  defp pick_node(map, {name, strategy}, channels, at, depth) do
    base = at <> "/" <> name

    with :ok <- only(map, [name], at),
         :ok <- channel_list(channels, base) do
      composite(channels, base, depth, &%{kind: :pick, at: at, strategy: strategy, children: &1})
    else
      {:error, errors} -> {nil, errors}
    end
  end

  defp composite(children, at, depth, build) when is_list(children) and children != [] do
    {nodes, errors} =
      children
      |> Enum.with_index()
      |> Enum.map(fn {child, index} -> node(child, "#{at}/#{index}", depth + 1) end)
      |> Enum.unzip()

    case List.flatten(errors) do
      [] -> {build.(nodes), []}
      errors -> {nil, errors}
    end
  end

  defp composite(children, at, _depth, _build) when is_list(children),
    do: {nil, [error(at, "too_short", "a list names at least one node")]}

  defp composite(_children, at, _depth, _build),
    do: {nil, [error(at, "invalid_format", "a list of nodes")]}

  defp channel_list(channels, at) when is_list(channels) do
    cond do
      not Enum.all?(channels, &is_binary/1) ->
        {:error, [error(at, "invalid_format", "a list of channel names")]}

      length(Enum.uniq(channels)) != length(channels) ->
        {:error, [error(at, "conflict", "a channel is named once")]}

      true ->
        :ok
    end
  end

  defp channel_list(_channels, at),
    do: {:error, [error(at, "invalid_format", "a list of channel names")]}

  defp trigger(%{"trigger" => "on_failure"}, _at), do: {:ok, nil}

  defp trigger(%{"trigger" => %{"after_delay" => text} = t}, at) when map_size(t) == 1,
    do: positive(text, at <> "/trigger/after_delay")

  defp trigger(%{"trigger" => _other}, at),
    do: {:error, [error(at <> "/trigger", "unsupported_value", "on_failure or after_delay")]}

  defp trigger(_map, _at), do: {:ok, nil}

  # WF-15
  defp positive(text, at) do
    case duration_ms(text) do
      {:ok, 0} -> {:error, [error(at, "unsupported_value", "a delay is above zero")]}
      {:ok, ms} -> {:ok, ms}
      :error -> {:error, [error(at, "invalid_format", "an ISO 8601 duration")]}
    end
  end

  # WF-21
  defp escalate_node(map, at, depth) do
    base = at <> "/escalate"

    with :ok <- only(map, ["escalate"], at),
         {:ok, escalate} <- escalate_map(map["escalate"], base),
         {:ok, condition} <- condition(escalate, base),
         {:ok, event_type} <- event_type(condition, escalate["event_type"], base) do
      ladder_node(escalate["ladder"], at, depth, {condition, event_type})
    else
      {:error, errors} -> {nil, errors}
    end
  end

  defp escalate_map(escalate, at) when is_map(escalate) do
    case only(escalate, ["unless", "event_type", "ladder"], at) do
      :ok -> {:ok, escalate}
      {:error, errors} -> {:error, errors}
    end
  end

  defp escalate_map(_escalate, at), do: {:error, [shape(at)]}

  defp condition(%{"unless" => text}, at) do
    case Map.fetch(@unless, text) do
      {:ok, condition} -> {:ok, condition}
      :error -> {:error, [error(at <> "/unless", "unsupported_value", "an unknown condition")]}
    end
  end

  defp condition(_escalate, at),
    do: {:error, [error(at <> "/unless", "required", "a stop condition")]}

  defp event_type(:event, type, at) when is_binary(type) do
    if Regex.match?(@event_type, type),
      do: {:ok, type},
      else: {:error, [error(at <> "/event_type", "invalid_format", "an event type")]}
  end

  defp event_type(:event, _type, at),
    do: {:error, [error(at <> "/event_type", "required", "an event condition names its type")]}

  defp event_type(_condition, nil, _at), do: {:ok, nil}

  defp event_type(_condition, _type, at),
    do: {:error, [error(at <> "/event_type", "not_allowed", "only an event has a type")]}

  defp ladder_node(steps, at, depth, {condition, type}) when is_list(steps) and steps != [] do
    base = at <> "/escalate/ladder"

    {rungs, errors} =
      steps
      |> Enum.with_index()
      |> Enum.map(fn {step, index} -> rung(step, "#{base}/#{index}", depth) end)
      |> Enum.unzip()

    case List.flatten(errors) do
      [] -> {%{kind: :escalate, at: at, unless: condition, event_type: type, ladder: rungs}, []}
      errors -> {nil, errors}
    end
  end

  defp ladder_node(_steps, at, _depth, _condition),
    do: {nil, [error(at <> "/escalate/ladder", "too_short", "a ladder has at least one step")]}

  defp rung(%{"after" => text, "node" => child} = step, at, depth) when map_size(step) == 2 do
    with {:ok, ms} <- positive(text, at <> "/after"),
         {node, []} <- node(child, at <> "/node", depth + 1) do
      {{ms, node}, []}
    else
      {:error, errors} -> {nil, errors}
      {nil, errors} -> {nil, errors}
    end
  end

  defp rung(_step, at, _depth), do: {nil, [error(at, "invalid_format", "after and node")]}

  defp only(map, keys, at) do
    if Map.keys(map) -- keys == [], do: :ok, else: {:error, [shape(at)]}
  end

  defp shape(at), do: error(at, "invalid_format", "not a route node")

  defp error(at, code, detail), do: %{pointer: at, code: code, detail: detail}

  defp duration_ms(text) when is_binary(text) do
    case Regex.run(@duration, text) do
      [_ | parts] ->
        parts = parts ++ List.duplicate("", length(@units) - length(parts))
        {:ok, parts |> Enum.zip(@units) |> Enum.reduce(0, &add_unit/2)}

      nil ->
        :error
    end
  end

  defp duration_ms(_text), do: :error

  defp add_unit({"", _unit}, acc), do: acc
  defp add_unit({digits, unit}, acc), do: acc + String.to_integer(digits) * unit
end
