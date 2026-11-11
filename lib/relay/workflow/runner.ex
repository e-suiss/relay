defmodule Relay.Workflow.Runner do
  @moduledoc """
  The workflow run engine (WF-59 (5), WF-43, WF-6). A run is one notification's walk through the step tree of the workflow version it started on; it never moves to a newer version. Its state is JSON: a cursor (the stack of step lists it is in, each frame the path of a list in the definition and the index of the current step, the innermost first), the results recorded under each step's key, the routes of its channel steps, the time the cursor waits for and the digest step it is parked on.

  `advance/5` is pure apart from the callbacks it is given. It first evaluates every running route again, then runs the steps from the cursor on, each through its module (`Relay.Workflow.Step`), until a step waits, parks, ends the run or the tree ends:

  * a channel step's `{:route, result}` evaluates the tree the notification's plan holds for the step (WF-7) with `Relay.Workflow.RouteTree.next/3`: each leaf to open goes to the opener with its RFC 6901 pointer, which opens its delivery in the caller's transaction and returns the delivery identifiers and its own extras; a leaf to skip and an escalation that stopped are recorded under their pointer; the route keeps running with its `wake_at` while it is not delivered, exhausted or stopped and can still open a leaf (a route whose every leaf is open and that has no timer is `settled`), and the cursor goes on at once;
  * a route is evaluated again whenever the run wakes: at its `wake_at` (an `after_delay` fallback, an escalation step) and when one of its deliveries settles, with the leaf statuses and the reliable engagement evidence of the delivery projection (WF-15, WF-21, WF-22);
  * `{:park, result}` holds the cursor after the step until the caller resumes the run (a digest anchor waiting for its window, WF-27, or an open event wait, WF-12, resumed by `resume_wait/3` with `matched` or with `timed_out` and its `on_timeout` steps); `{:end, result}` ends the run completed (a folded digest item);
  * a channel step with A/B variants (WF-50) evaluates its route with the template of the variant its result records;
  * every other instruction only moves the cursor; when a branch list ends, the run goes on with the step after its branching step.

  The run then waits (a timer at the earliest of the cursor's and the routes' times), keeps running without a timer (a route waiting on a delivery outcome, a parked cursor) or completes. The same definition, context, step results and projection always give the same path.

  `outcomes/2` turns the recorded results and the deliveries' current projection into the condition view of each step (`steps.<key>.<result>`): `delivered`, `failed`, `skipped`, `seen`, `read`, `clicked` (human clicks only, WF-22) and the step's own `throttled`, `timed_out` and `matched`.
  """

  alias Relay.Workflow.Definition
  alias Relay.Workflow.RouteTree
  alias Relay.Workflow.Step

  @max_moves 500
  @unavailable "workflow_run.route_unavailable"

  @type frame :: %{String.t() => term()}
  @type state :: %{String.t() => term()}
  @type opener :: (map(), String.t(), String.t() ->
                     {:ok, [String.t()], [term()]} | {:error, term()})
  @type outcome :: %{
          state: state(),
          status: String.t(),
          wake_at: DateTime.t() | nil,
          outcome: String.t() | nil,
          rule_id: String.t() | nil,
          extras: [term()]
        }

  # WF-59 (5)
  @doc "The state of a run that has not run any step."
  @spec new() :: state()
  def new,
    do: %{
      "cursor" => [%{"list" => ["steps"], "index" => 0}],
      "results" => %{},
      "routes" => %{},
      "cursor_wake_at" => nil,
      "parked" => nil
    }

  # WF-59 (5)
  # WF-43
  # WF-13
  @doc "Evaluates the running routes again and runs the cursor forward at business time `now`; the outcome's status is `waiting` (with `wake_at`), `running` (no timer) or `completed`."
  @spec advance(map(), state(), map(), DateTime.t(), opener()) ::
          {:ok, outcome()} | {:error, term()}
  def advance(definition, state, context, now, opener) do
    state = Map.merge(new(), state)

    with {:ok, state, extras} <- refresh(definition, state, context, now, opener),
         {:ok, state, more, ending} <- cursor(definition, state, context, now, opener) do
      {:ok, finish(state, ending, extras ++ more)}
    end
  end

  defp cursor(definition, state, context, now, opener) do
    cond do
      state["parked"] != nil ->
        {:ok, state, [], nil}

      waiting?(state["cursor_wake_at"], now) ->
        {:ok, state, [], nil}

      true ->
        state = %{state | "cursor_wake_at" => nil}
        move(definition, state, context, now, opener, [], @max_moves)
    end
  end

  defp waiting?(nil, _now), do: false
  defp waiting?(text, now), do: DateTime.compare(time(text), now) == :gt

  defp finish(state, {:stopped, rule_id}, extras),
    do: outcome(state, "completed", nil, "stopped", rule_id, extras)

  defp finish(state, :ended, extras),
    do: outcome(state, "completed", nil, "completed", nil, extras)

  defp finish(state, nil, extras) do
    running = for {_key, %{"status" => "running"} = route} <- state["routes"], do: route
    cursor_done? = state["cursor"] == [] and state["parked"] == nil
    times = Enum.reject([state["cursor_wake_at"] | Enum.map(running, & &1["wake_at"])], &is_nil/1)
    wake = times |> Enum.map(&time/1) |> Enum.min(DateTime, fn -> nil end)

    cond do
      cursor_done? and running == [] -> outcome(state, "completed", nil, "completed", nil, extras)
      wake != nil -> outcome(state, "waiting", wake, nil, nil, extras)
      true -> outcome(state, "running", nil, nil, nil, extras)
    end
  end

  defp outcome(state, status, wake_at, outcome, rule_id, extras),
    do: %{
      state: state,
      status: status,
      wake_at: wake_at,
      outcome: outcome,
      rule_id: rule_id,
      extras: extras
    }

  defp refresh(definition, state, context, now, opener) do
    running = for {key, %{"status" => "running"}} <- state["routes"], do: key
    ids = for key <- running, id <- leaf_deliveries(state["routes"][key]), do: id
    projection = if ids == [], do: %{}, else: context.projection.(ids)

    Enum.reduce_while(running, {:ok, state, []}, fn key, {:ok, state, extras} ->
      step =
        definition
        |> find_step(key)
        |> variant_step(state["results"][key])
        |> digest_step(state)

      case evaluate(step, state["routes"][key], projection, context, now, opener) do
        {:ok, route, more} -> {:cont, {:ok, put_route(state, step, route, now), extras ++ more}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp move(_definition, _state, _context, _now, _opener, _extras, 0),
    do: {:error, :too_many_moves}

  defp move(_definition, %{"cursor" => []} = state, _context, _now, _opener, extras, _left),
    do: {:ok, state, extras, nil}

  defp move(definition, %{"cursor" => [frame | rest]} = state, context, now, opener, extras, left) do
    case step_at(definition, frame) do
      nil ->
        move(definition, %{state | "cursor" => pop(rest)}, context, now, opener, extras, left - 1)

      step ->
        context = Map.put(context, :results, state["results"])
        instruction = Step.module(step["type"]).run(step, context, now)
        follow(instruction, step, {definition, state, context, now, opener, extras, left})
    end
  end

  defp follow({:error, reason}, _step, _acc), do: {:error, reason}

  defp follow({:continue, result}, step, {definition, state, context, now, opener, extras, left}) do
    state = state |> record(step, result, now) |> next()
    move(definition, state, context, now, opener, extras, left - 1)
  end

  defp follow({:route, result}, step, {definition, state, context, now, opener, extras, left}) do
    case route(step |> variant_step(result) |> digest_step(state), result, context, now, opener) do
      {:ok, state_fun, more} ->
        state = state |> state_fun.() |> next()
        move(definition, state, context, now, opener, extras ++ more, left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow(
         {:wait_until, at, result},
         step,
         {_definition, state, _context, now, _opener, extras, _left}
       ) do
    state = state |> record(step, result, now) |> next()
    {:ok, %{state | "cursor_wake_at" => DateTime.to_iso8601(at)}, extras, nil}
  end

  defp follow({:park, result}, step, {_definition, state, _context, now, _opener, extras, _left}) do
    state = state |> record(step, result, now) |> next()
    {:ok, %{state | "parked" => step["key"]}, extras, nil}
  end

  defp follow({:end, result}, step, {_definition, state, _context, now, _opener, extras, _left}) do
    state = state |> record(step, result, now) |> next()
    {:ok, state, extras, :ended}
  end

  defp follow(
         {:branch, path, result},
         step,
         {definition, state, context, now, opener, extras, left}
       ) do
    [frame | _rest] = cursor = state["cursor"]
    inner = %{"list" => frame["list"] ++ [frame["index"] | path], "index" => 0}
    state = %{record(state, step, result, now) | "cursor" => [inner | cursor]}
    move(definition, state, context, now, opener, extras, left - 1)
  end

  defp follow(
         {:stop, rule_id, result},
         step,
         {_definition, state, _context, now, _opener, extras, _left}
       ) do
    state = state |> record(step, result, now) |> next()
    {:ok, state, extras, {:stopped, rule_id}}
  end

  # WF-7
  # WF-13
  defp route(step, result, context, now, opener) do
    case Map.get(context.routes, step["key"]) do
      %{"tree" => tree} ->
        fresh = %{
          "tree" => tree,
          "leaves" => %{},
          "stopped" => [],
          "status" => "running",
          "wake_at" => nil
        }

        with {:ok, route, more} <- evaluate(step, fresh, %{}, context, now, opener) do
          {:ok, &(&1 |> record(step, result, now) |> put_route(step, route, now)), more}
        end

      %{"skip" => rule_id} ->
        skipped = Map.merge(result, %{"outcome" => "skipped", "rule_id" => rule_id})
        {:ok, &record(&1, step, skipped, now), []}

      nil ->
        skipped = Map.merge(result, %{"outcome" => "skipped", "rule_id" => @unavailable})
        {:ok, &record(&1, step, skipped, now), []}
    end
  end

  # WF-13
  # WF-15
  # WF-21
  # WF-22
  defp evaluate(step, route, projection, context, now, opener, rounds \\ 10)

  defp evaluate(step, route, projection, context, now, opener, rounds) do
    with {:ok, next, extras} <- evaluate_once(step, route, projection, context, now, opener) do
      settle(step, route, next, extras, projection, {context, now, opener, rounds})
    end
  end

  defp settle(step, route, next, extras, projection, {context, now, opener, rounds}) do
    fresh = leaf_deliveries(next) -- leaf_deliveries(route)
    seen = if fresh == [] or rounds == 0, do: %{}, else: context.projection.(fresh)
    ended? = Enum.any?(Map.values(seen), &(status(&1["status"]) in [:failed, :skipped]))

    if ended? and next["status"] in ["running", "settled"] do
      merged = Map.merge(projection, seen)

      with {:ok, again, more} <- evaluate(step, next, merged, context, now, opener, rounds - 1),
           do: {:ok, again, extras ++ more}
    else
      {:ok, next, extras}
    end
  end

  defp evaluate_once(step, route, projection, context, now, opener) do
    leaves =
      for {pointer, leaf} <- route["leaves"],
          into: %{},
          do: {pointer, leaf_state(leaf, projection)}

    facts = context.facts.(step)

    case RouteTree.next(route["tree"], facts, %{now: now, leaves: leaves, events: []}) do
      {:ok, plan} ->
        apply_plan(step, route, plan, now, opener)

      {:error, _errors} ->
        {:ok, %{route | "status" => "exhausted", "rule_id" => @unavailable}, []}
    end
  end

  defp apply_plan(step, route, plan, now, opener) do
    at = DateTime.to_iso8601(now)

    opened =
      Enum.reduce_while(plan.open, {:ok, route["leaves"], []}, fn open, {:ok, leaves, extras} ->
        case opener.(step, open.channel, open.at) do
          {:ok, ids, more} ->
            leaf = %{
              "channel" => open.channel,
              "status" => "opened",
              "at" => at,
              "deliveries" => ids
            }

            {:cont, {:ok, Map.put(leaves, open.at, leaf), extras ++ more}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    with {:ok, leaves, extras} <- opened do
      leaves =
        Enum.reduce(plan.skip, leaves, fn skip, leaves ->
          leaf = %{
            "channel" => skip.channel,
            "status" => "skipped",
            "rule_id" => skip.rule_id,
            "at" => at
          }

          Map.put(leaves, skip.at, leaf)
        end)

      stopped =
        for stop <- plan.stopped,
            do: %{"at" => stop.at, "rule_id" => stop.rule_id, "signal" => to_string(stop.signal)}

      route = %{
        route
        | "leaves" => leaves,
          "stopped" => Enum.uniq(route["stopped"] ++ stopped),
          "status" => route_status(route["tree"], leaves, plan),
          "wake_at" => plan.wake_at && DateTime.to_iso8601(plan.wake_at)
      }

      {:ok, Map.put(route, "rule_id", plan.rule_id), extras}
    end
  end

  defp route_status(tree, leaves, %{status: :running, wake_at: nil}) do
    opened? =
      Enum.all?(RouteTree.leaf_pointers(tree), fn {pointer, _channel} ->
        Map.has_key?(leaves, pointer)
      end)

    if opened?, do: "settled", else: "running"
  end

  defp route_status(_tree, _leaves, plan), do: Atom.to_string(plan.status)

  defp leaf_state(%{"status" => "skipped", "at" => at}, _projection),
    do: %{status: :skipped, at: time(at)}

  defp leaf_state(%{"deliveries" => ids, "at" => at}, projection) do
    rows = for id <- ids, row = projection[id], row != nil, do: row

    case rows do
      [] -> %{status: if(ids == [], do: :skipped, else: :pending), at: time(at)}
      [row | _rest] -> %{status: status(row["status"]), at: time(at), evidence: evidence(row)}
    end
  end

  defp status("delivered"), do: :delivered
  defp status(failed) when failed in ["failed", "expired"], do: :failed
  defp status(skipped) when skipped in ["skipped", "cancelled"], do: :skipped
  defp status("unknown"), do: :unknown
  defp status(_queued_or_sent), do: :pending

  defp evidence(row) do
    [
      {row["seen"], %{signal: :seen, decision_grade: :reliable}},
      {row["read"], %{signal: :read, decision_grade: :reliable}},
      {row["clicked"], %{signal: :clicked, decision_grade: :reliable, actor: :human}}
    ]
    |> Enum.filter(&(elem(&1, 0) == true))
    |> Enum.map(&elem(&1, 1))
  end

  defp put_route(state, step, route, now) do
    key = step["key"]
    ids = leaf_deliveries(route)
    result = Map.get(state["results"], key, %{"type" => "channel"})

    result =
      Map.merge(result, %{
        "outcome" => "routed",
        "deliveries" => ids,
        "route_status" => route["status"],
        "digest" => step["digest"] == true,
        "at" => DateTime.to_iso8601(now)
      })

    %{
      state
      | "routes" => Map.put(state["routes"], key, route),
        "results" => Map.put(state["results"], key, result)
    }
  end

  # WF-27
  defp digest_step(%{"digest_template" => template} = step, %{"digest" => %{"kind" => "digest"}}),
    do: Map.merge(step, %{"template" => template, "digest" => true})

  defp digest_step(step, _state), do: step

  # WF-50
  defp variant_step(step, %{"variant_template" => template} = result) when is_binary(template),
    do: Map.merge(step, %{"template" => template, "variant" => result["variant"]})

  defp variant_step(step, _result), do: step

  defp leaf_deliveries(route),
    do: route["leaves"] |> Map.values() |> Enum.flat_map(&(&1["deliveries"] || []))

  defp find_step(definition, key) do
    definition
    |> Definition.entries()
    |> Enum.find_value(fn %{step: step} -> if step["key"] == key, do: step end)
  end

  defp step_at(definition, %{"list" => path, "index" => index}) do
    case Definition.get(definition, Enum.map(path, &to_string/1)) do
      {:ok, list} when is_list(list) -> Enum.at(list, index)
      _missing -> nil
    end
  end

  defp record(state, step, result, now) do
    entry = Map.merge(result, %{"type" => step["type"], "at" => DateTime.to_iso8601(now)})
    %{state | "results" => Map.put(state["results"], step["key"], entry)}
  end

  defp next(%{"cursor" => [frame | rest]} = state),
    do: %{state | "cursor" => [%{frame | "index" => frame["index"] + 1} | rest]}

  defp pop([]), do: []
  defp pop([parent | rest]), do: [%{parent | "index" => parent["index"] + 1} | rest]

  defp time(text) do
    {:ok, at, _offset} = DateTime.from_iso8601(text)
    at
  end

  # WF-27
  @doc "Unparks a run's cursor after a digest window fired, recording the digest outcome (`kind` `digest` with its render data, or `single`) under the parked step."
  @spec unpark(state(), String.t(), map()) :: state()
  def unpark(%{"parked" => key} = state, kind, render) when is_binary(key) do
    result = Map.merge(state["results"][key] || %{}, %{"outcome" => kind, "render" => render})
    digest = %{"kind" => kind, "step" => key}

    %{state | "parked" => nil, "results" => Map.put(state["results"], key, result)}
    |> Map.put("digest", digest)
  end

  def unpark(state, _kind, _render), do: state

  # WF-12
  @doc "Resumes a run parked on a `wait_for_event` step after its wait closed: `:matched` records the step `matched` and goes on with the next step; `:timed_out` records it `timed_out` and enters the step's `on_timeout` steps, after which the run goes on with the step after the wait."
  @spec resume_wait(state(), String.t(), :matched | :timed_out) :: state()
  def resume_wait(%{"parked" => key, "cursor" => [frame | rest]} = state, key, outcome) do
    result = Map.merge(state["results"][key] || %{}, wait_result(outcome))
    state = %{state | "parked" => nil, "results" => Map.put(state["results"], key, result)}

    case outcome do
      :matched ->
        state

      :timed_out ->
        index = frame["index"] - 1
        inner = %{"list" => frame["list"] ++ [index, "on_timeout"], "index" => 0}
        %{state | "cursor" => [inner, %{frame | "index" => index} | rest]}
    end
  end

  def resume_wait(state, _key, _outcome), do: state

  defp wait_result(:matched), do: %{"outcome" => "matched", "matched" => true}
  defp wait_result(:timed_out), do: %{"outcome" => "timed_out", "timed_out" => true}

  # WF-60
  # WF-22
  @doc "The condition view of the recorded step results, given each delivery's current projection (`status`, `seen`, `read`, `clicked` by identifier)."
  @spec outcomes(%{String.t() => map()}, %{String.t() => map()}) :: %{String.t() => map()}
  def outcomes(results, deliveries) do
    Map.new(results, fn {key, result} ->
      rows = for id <- result["deliveries"] || [], row = deliveries[id], row != nil, do: row
      statuses = Enum.map(rows, & &1["status"])

      {key,
       %{
         "delivered" =>
           Enum.any?(rows, &(&1["status"] == "delivered" or &1["seen"] or &1["read"])),
         "failed" => "failed" in statuses,
         "skipped" =>
           result["outcome"] == "skipped" or
             (rows != [] and Enum.all?(statuses, &(&1 == "skipped"))),
         "seen" => Enum.any?(rows, & &1["seen"]),
         "read" => Enum.any?(rows, & &1["read"]),
         "clicked" => Enum.any?(rows, & &1["clicked"]),
         "throttled" => result["throttled"] == true,
         "timed_out" => result["timed_out"] == true,
         "matched" => result["matched"] == true
       }}
    end)
  end

  @doc "The delivery identifiers recorded in the step results."
  @spec delivery_ids(%{String.t() => map()}) :: [String.t()]
  def delivery_ids(results),
    do: results |> Map.values() |> Enum.flat_map(&(&1["deliveries"] || [])) |> Enum.uniq()
end
