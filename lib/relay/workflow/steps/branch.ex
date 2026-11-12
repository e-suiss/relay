defmodule Relay.Workflow.Steps.Branch do
  @moduledoc """
  The condition step (WF-10, WF-60): evaluates its branches in order with `Relay.Workflow.Condition` and enters the first branch whose condition holds, else the `else` list; without a match and without `else` the run goes on with the next step. The earlier steps' results are read from the delivery projection at evaluation time.
  """

  @behaviour Relay.Workflow.Step

  # WF-10
  # WF-60
  @impl Relay.Workflow.Step
  def run(step, context, _now) do
    view = %{
      data: context.data,
      recipient: context.recipient,
      steps: context.outcomes.(context.results),
      event_time: context.event_time,
      run_started_at: context.run_started_at
    }

    branches = Enum.with_index(step["branches"] || [])
    otherwise = step["else"]

    case Enum.find(branches, fn {branch, _index} ->
           Relay.Workflow.Condition.evaluate(branch["when"], view)
         end) do
      {_branch, index} ->
        {:branch, ["branches", index, "steps"], %{"outcome" => "branch", "branch" => index}}

      nil when is_list(otherwise) ->
        {:branch, ["else"], %{"outcome" => "else"}}

      nil ->
        {:continue, %{"outcome" => "no_match"}}
    end
  end
end
