defmodule Relay.Workflow.DefinitionTest do
  use ExUnit.Case, async: true

  alias Relay.Workflow.Definition

  @step %{"type" => "channel", "key" => "mail", "channel" => "email", "template" => "w"}

  defp definition(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Welcome",
        "category" => "accounts",
        "message_class" => "transactional",
        "event_schema" => %{"type" => "object"},
        "steps" => [@step]
      },
      overrides
    )
  end

  describe "WF-1 WF-5 publication gate" do
    test "WF-1: a valid definition passes the gate" do
      assert Definition.gate(definition()) == []
    end

    test "WF-1: an event schema that does not build or reaches the network is refused" do
      assert [%{pointer: "/definition/event_schema"}] =
               Definition.gate(definition(%{"event_schema" => %{"type" => 5}}))

      remote = %{"$ref" => "https://example.com/schema.json"}

      assert [%{pointer: "/definition/event_schema"}] =
               Definition.gate(definition(%{"event_schema" => remote}))
    end

    test "WF-8: step keys are unique" do
      assert [%{pointer: "/definition/steps/1/key", code: "conflict"}] =
               Definition.gate(definition(%{"steps" => [@step, @step]}))
    end

    test "WF-5: the digest does not depend on key order" do
      a = %{"b" => 1, "a" => %{"y" => 2.5, "x" => [1, 2]}}
      b = %{"a" => %{"x" => [1, 2], "y" => 2.5}, "b" => 1}
      assert Relay.Workflow.definition_digest(a) == Relay.Workflow.definition_digest(b)
    end
  end
end
