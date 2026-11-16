defmodule Relay.Workflow.VariantTest do
  use ExUnit.Case, async: true

  alias Relay.Workflow.Variant

  @step %{
    "type" => "channel",
    "key" => "mail",
    "channel" => "email",
    "template" => "base",
    "variants" => [
      %{"key" => "a", "weight" => 3, "template" => "t-a"},
      %{"key" => "b", "weight" => 1, "template" => "t-b"}
    ]
  }

  describe "WF-50 A/B variants" do
    test "WF-50: a recipient always lands in the same variant and the split follows the weights" do
      ids = for _ <- 1..2_000, do: Relay.Id.generate()
      chosen = Enum.map(ids, &Variant.choose("order-shipped", @step, &1))

      assert chosen == Enum.map(ids, &Variant.choose("order-shipped", @step, &1))

      assert Enum.all?(
               chosen,
               &(&1 in [
                   %{"key" => "a", "template" => "t-a"},
                   %{"key" => "b", "template" => "t-b"}
                 ])
             )

      share = Enum.count(chosen, &(&1["key"] == "a")) / length(chosen)
      assert share > 0.68 and share < 0.82
    end

    test "WF-50: the choice depends on the workflow and the step, and covers every variant step" do
      id = Relay.Id.generate()
      definition = %{"steps" => [@step, Map.put(@step, "key", "other")]}

      assert %{"mail" => %{"key" => _}, "other" => %{"key" => _}} =
               Variant.choose_all(definition, "order-shipped", id)

      assert Variant.templates(definition) == ["t-a", "t-b", "t-a", "t-b"]
      assert Variant.choose("w", @step, Relay.Id.to_string(id)) == Variant.choose("w", @step, id)
    end
  end
end
