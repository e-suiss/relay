defmodule Relay.Workflow.Runner do
  @moduledoc """
  The workflow run engine (WF-59 (5), WF-43, WF-6). A run is one notification's walk through the step tree of the workflow version it started on; it never moves to a newer version. Its state is JSON: a cursor, the stack of step lists it is in (each frame the path of a list in the definition and the index of the current step, the innermost first), and the results recorded under each step's key.

  `advance/5` is pure apart from the opener it is given: it runs the steps from the cursor on, each through its module (`Relay.Workflow.Step`), until a step waits, the run stops or the tree ends. A channel step's `{:open, channel, result}` calls the opener, which opens the step's deliveries in the caller's transaction and returns their identifiers and its own extras (the accept answer's decisions); every other instruction only moves the cursor. When a branch list ends, the run goes on with the step after its branching step. The same definition, context and step results always give the same path.

  `outcomes/2` turns the recorded results and the deliveries' current projection into the condition view of each step (`steps.<key>.<result>`): `delivered`, `failed`, `skipped`, `seen`, `read`, `clicked` (human clicks only, WF-22) and the step's own `throttled`, `timed_out` and `matched`.
  """

  alias Relay.Workflow.Step

  @max_moves 500

  @type frame :: %{String.t() => term()}
  @type state :: %{String.t() => term()}
  @type opener :: (map(), String.t() -> {:ok, [String.t()], [term()]} | {:error, term()})
  @type outcome ::
          {:waiting, DateTime.t(), state(), [term()]}
          | {:completed, String.t(), String.t() | nil, state(), [term()]}

  # WF-59 (5)
  @doc "The state of a run that has not run any step."
  @spec new() :: state()
  def new, do: %{"cursor" => [%{"list" => ["steps"], "index" => 0}], "results" => %{}}

  # WF-59 (5)
  # WF-43
  @doc "Runs a state forward from its cursor at business time `now` until it waits, stops or completes."
  @spec advance(map(), state(), map(), DateTime.t(), opener()) ::
          {:ok, outcome()} | {:error, term()}
  def advance(definition, state, context, now, opener),
    do: move(definition, state, context, now, opener, [], @max_moves)

  defp move(_definition, _state, _context, _now, _opener, _extras, 0),
    do: {:error, :too_many_moves}

  defp move(_definition, %{"cursor" => []} = state, _context, _now, _opener, extras, _left),
    do: {:ok, {:completed, "completed", nil, state, extras}}

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

  defp follow({:continue, result}, step, {definition, state, context, now, opener, extras, left}) do
    state = state |> record(step, result, now) |> next()
    move(definition, state, context, now, opener, extras, left - 1)
  end

  defp follow(
         {:open, channel, result},
         step,
         {definition, state, context, now, opener, extras, left}
       ) do
    case opener.(step, channel) do
      {:ok, ids, more} ->
        state = state |> record(step, Map.put(result, "deliveries", ids), now) |> next()
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
    {:ok, {:waiting, at, state, extras}}
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
    {:ok, {:completed, "stopped", rule_id, state, extras}}
  end

  defp step_at(definition, %{"list" => path, "index" => index}) do
    case Relay.Workflow.Definition.get(definition, Enum.map(path, &to_string/1)) do
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
