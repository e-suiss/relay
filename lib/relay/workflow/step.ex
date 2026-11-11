defmodule Relay.Workflow.Step do
  @moduledoc """
  The step-dispatch seam of the workflow runner (WF-8, WF-59). Every step type is one module that implements this behaviour: `run/3` takes the step as written in the definition, the run context and the business time, and returns one instruction; it writes nothing itself, only through the context's effects (`digest`, `throttle`, `wait`), which run in the caller's transaction. `module/1` maps a step type to its module; a type that is not executable yet maps to `Relay.Workflow.Steps.Unavailable`, which records `workflow_run.step_unavailable` as the step's outcome instead of skipping it silently.

  The instructions:

  * `{:continue, result}`: the step is done; the run goes on with the next step.
  * `{:route, result}`: the runner evaluates the step's route tree from the notification's plan, opening its leaves through the opener, and goes on while the route keeps running.
  * `{:wait_until, at, result}`: the run waits as a row with a timer until `at` (WF-43) and goes on with the next step when it wakes.
  * `{:branch, path, result}`: the run enters the step list at `path` under the step (such as `["branches", 0, "steps"]` or `["else"]`); when that list ends, it goes on with the step after this one.
  * `{:park, result}`: the cursor waits after the step until the run is resumed (a digest anchor, an open event wait).
  * `{:end, result}`: the run ends completed (a folded digest item).
  * `{:stop, rule_id, result}`: the run ends with the outcome `stopped` and the rule.
  * `{:error, reason}`: an effect could not be applied; the caller's transaction rolls back.

  A result is a JSON object recorded under the step's key in the run's step results: at least `outcome` and, for an outcome that is not a success, `rule_id`. The context (`t:context/0`) carries the business time base, the event data, the declared recipient attributes, the recipient's time zone, the event time, the run's start, the class, the earlier step results, `outcomes` (a function from the step results to the condition view of every earlier step, `steps.<key>.<result>`, read from the delivery projection at evaluation time), `projection` (delivery identifiers to their projection), `routes` (the step trees of the plan), `facts` (a step's route facts) and `effects`.
  """

  @type result :: %{String.t() => term()}
  @type instruction ::
          {:continue, result()}
          | {:route, result()}
          | {:park, result()}
          | {:end, result()}
          | {:error, term()}
          | {:wait_until, DateTime.t(), result()}
          | {:branch, [String.t() | non_neg_integer()], result()}
          | {:stop, String.t(), result()}

  @type context :: %{
          required(:data) => term(),
          required(:recipient) => map(),
          required(:time_zone) => Relay.TimeZone.t() | nil,
          required(:event_time) => DateTime.t() | nil,
          required(:run_started_at) => DateTime.t(),
          required(:message_class) => String.t() | nil,
          required(:results) => %{String.t() => result()},
          required(:outcomes) => (%{String.t() => result()} -> %{String.t() => map()})
        }

  @doc "Runs one step against the run context at a business time."
  @callback run(step :: map(), context :: context(), now :: DateTime.t()) :: instruction()

  @modules %{
    "channel" => Relay.Workflow.Steps.Channel,
    "delay" => Relay.Workflow.Steps.Delay,
    "condition" => Relay.Workflow.Steps.Branch,
    "digest" => Relay.Workflow.Steps.Digest,
    "throttle" => Relay.Workflow.Steps.Throttle,
    "time_window" => Relay.Workflow.Steps.TimeWindow,
    "wait_for_event" => Relay.Workflow.Steps.WaitForEvent
  }

  # WF-8
  @doc "The module that runs a step type."
  @spec module(String.t()) :: module()
  def module(type), do: Map.get(@modules, type, Relay.Workflow.Steps.Unavailable)
end
