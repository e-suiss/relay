defmodule Relay.Workflow.Variant do
  @moduledoc """
  The A/B split of a channel step (WF-50): a step carries two to ten weighted variants, each with its own template. A recipient's variant is chosen deterministically from the SHA-256 of the workflow key, the step key and the recipient identifier, read as an integer modulo the total weight, so the same recipient always lands in the same variant of the same experiment and the split follows the weights. The choice is made once, when the notification is accepted, and frozen in the run's plan (WF-7): a later change of the weights or the variants never moves a notification that already started.
  """

  alias Relay.Workflow.Definition

  # WF-50
  # WF-7
  @doc "The variant of every channel step with variants, chosen for the recipient: a map of step key to `%{\"key\", \"template\"}`."
  @spec choose_all(map(), String.t(), Relay.Id.t() | String.t()) :: %{String.t() => map()}
  def choose_all(definition, workflow_key, recipient_id) do
    for %{step: %{"type" => "channel", "variants" => [_ | _]} = step} <-
          Definition.entries(definition),
        into: %{},
        do: {step["key"], choose(workflow_key, step, recipient_id)}
  end

  # WF-50
  @doc "The variant of one step for a recipient."
  @spec choose(String.t(), map(), Relay.Id.t() | String.t()) :: map()
  def choose(workflow_key, %{"key" => step_key, "variants" => variants}, recipient_id) do
    total = variants |> Enum.map(& &1["weight"]) |> Enum.sum()
    <<number::unsigned-big-integer-size(256)>> = digest(workflow_key, step_key, recipient_id)
    pick(variants, rem(number, total))
  end

  @doc "The template keys of every variant of a definition's channel steps."
  @spec templates(map()) :: [String.t()]
  def templates(definition) do
    for %{step: %{"type" => "channel", "variants" => [_ | _] = variants}} <-
          Definition.entries(definition),
        variant <- variants,
        do: variant["template"]
  end

  defp digest(workflow_key, step_key, recipient_id),
    do: :crypto.hash(:sha256, Enum.join([workflow_key, step_key, text(recipient_id)], <<0>>))

  defp text(<<_::128>> = id), do: Relay.Id.to_string(id)
  defp text(id) when is_binary(id), do: id

  defp pick([variant | rest], point) do
    if point < variant["weight"] or rest == [],
      do: %{"key" => variant["key"], "template" => variant["template"]},
      else: pick(rest, point - variant["weight"])
  end
end
