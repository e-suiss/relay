defmodule Relay.Workflow.StepTimingTest do
  use ExUnit.Case, async: true

  alias Relay.Workflow.Definition

  @step %{"type" => "channel", "key" => "phone", "channel" => "push", "template" => "w"}
  @pointer "/definition/steps/0/max_defer"

  defp gate(step) do
    definition = %{
      "name" => "Reminder",
      "category" => "accounts",
      "message_class" => "transactional",
      "event_schema" => %{"type" => "object"},
      "steps" => [Map.merge(@step, step)]
    }

    definition |> Definition.gate() |> Enum.map(&{&1.pointer, &1.code})
  end

  defp next_break(max_defer), do: %{"timing" => "next_break", "max_defer" => max_defer}

  describe "WF-56 step timing" do
    test "WF-56: a channel step's next_break needs max_defer above zero and at most P30D" do
      assert gate(next_break("PT2H")) == []
      assert gate(%{"timing" => "immediate"}) == []
      assert gate(%{"timing" => "next_break"}) == [{@pointer, "required"}]
      assert gate(next_break("PT0S")) == [{@pointer, "too_short"}]
      assert gate(next_break("P31D")) == [{@pointer, "too_long"}]
      assert gate(%{"max_defer" => "PT1H"}) == [{@pointer, "not_allowed"}]
    end
  end
end
