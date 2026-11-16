defmodule Relay.Workflow.Steps.Channel do
  @moduledoc """
  The channel step (WF-8, WF-13): hands the step to the run's route evaluation (`{:route, result}`), which sends through the tree the notification's plan holds for it (its `channel`, its `route` or the category's default route, WF-14). A step with A/B variants (WF-50) sends the template of the recipient's variant, chosen at acceptance and frozen in the plan (`Relay.Workflow.Variant`); the result records the variant's key, which every delivery of the step carries in its step results and the variant report counts.
  """

  @behaviour Relay.Workflow.Step

  # WF-13
  # WF-50
  @impl Relay.Workflow.Step
  def run(%{"variants" => [_ | _]} = step, context, _now) do
    variant =
      context
      |> Map.get(:variants, %{})
      |> Map.get(step["key"], %{"key" => nil, "template" => step["template"]})

    {:route,
     %{
       "outcome" => "routed",
       "variant" => variant["key"],
       "variant_template" => variant["template"]
     }}
  end

  def run(_step, _context, _now), do: {:route, %{"outcome" => "routed"}}
end
