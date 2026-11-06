defmodule Relay.Api.WorkflowOverridesTest do
  use ExUnit.Case, async: true

  alias Relay.Api.Workflows

  @step %{"type" => "channel", "key" => "alert", "channel" => "push", "template" => "w"}

  defp definition(fields) do
    Map.merge(
      %{
        "name" => "Alert",
        "category" => "accounts",
        "event_schema" => %{"type" => "object"},
        "steps" => [@step]
      },
      fields
    )
  end

  describe "API-23 workflow and step overrides" do
    test "API-23: a raw block of the workflow or a step cannot set a policy field" do
      workflow = %{"push" => %{"raw" => %{"priority" => "high"}}}
      step = Map.put(@step, "overrides", %{"push" => %{"raw" => %{"Interruption-Level" => "x"}}})

      assert {:error, %Relay.Error{code: :policy_field_not_overridable, details: details}} =
               Workflows.definition(definition(%{"overrides" => workflow, "steps" => [step]}))

      assert Enum.map(details.errors, & &1.pointer) == [
               "/definition/overrides/push/raw/priority",
               "/definition/steps/0/overrides/push/raw/Interruption-Level"
             ]
    end

    test "API-23: a step overrides only its own channel" do
      step = Map.put(@step, "overrides", %{"email" => %{"from" => "news@mail.example.com"}})

      assert {:error, %Relay.Error{code: :validation_failed, details: details}} =
               Workflows.definition(definition(%{"steps" => [step]}))

      assert [%{pointer: "/definition/steps/0/overrides/email", code: "not_allowed"}] =
               details.errors
    end
  end
end
