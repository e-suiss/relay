defmodule Relay.Workflow.ConditionTest do
  use ExUnit.Case, async: true

  alias Relay.Workflow.Condition

  @scope %{attributes: %{"plan" => "string", "joined_at" => "timestamp"}, steps: ["mail"]}

  @context %{
    data: %{"order" => %{"total" => 120, "id" => "A-1", "tags" => ["vip", "new"]}, "n" => "5"},
    recipient: %{"plan" => "gold", "joined_at" => ~U[2026-01-01 00:00:00Z]},
    steps: %{"mail" => %{"delivered" => true, "clicked" => false}},
    event_time: ~U[2026-11-11 10:00:00Z],
    run_started_at: ~U[2026-11-11 10:00:00Z]
  }

  defp var(path), do: %{"var" => path}
  defp eval(condition), do: Condition.evaluate(condition, @context)

  describe "WF-60 operators" do
    test "WF-60: comparisons compare values of the same kind" do
      assert eval(%{"eq" => [var("data.order.id"), "A-1"]})
      assert eval(%{"gt" => [var("data.order.total"), 100]})
      assert eval(%{"lte" => [var("data.order.total"), 120]})
      refute eval(%{"lt" => [var("data.order.total"), 120]})
      assert eval(%{"ne" => [var("recipient.plan"), "silver"]})
      assert eval(%{"in" => [var("recipient.plan"), ["gold", "platinum"]]})
      assert eval(%{"not_in" => [var("recipient.plan"), ["silver"]]})
      assert eval(%{"contains" => [var("data.order.tags"), "vip"]})
      assert eval(%{"starts_with" => [var("data.order.id"), "A-"]})
      assert eval(%{"ends_with" => [var("data.order.id"), "-1"]})
      assert eval(%{"exists" => var("data.order.id")})
      refute eval(%{"exists" => var("data.order.missing")})
    end

    test "WF-60: there is no type conversion and a mismatch or a missing path is false or null" do
      refute eval(%{"eq" => [var("data.n"), 5]})
      refute eval(%{"gt" => [var("data.n"), 1]})
      refute eval(%{"ne" => [var("data.n"), 5]})
      refute eval(%{"gt" => [var("data.order.missing"), 1]})
      assert eval(%{"eq" => [var("data.order.missing"), nil]})
      refute eval(%{"starts_with" => [var("data.order.total"), "1"]})
    end

    test "WF-60: logical operators combine conditions" do
      yes = %{"eq" => [var("data.order.id"), "A-1"]}
      no = %{"eq" => [var("data.order.id"), "B-2"]}
      assert eval(%{"all" => [yes, %{"not" => no}]})
      assert eval(%{"any" => [no, yes]})
      refute eval(%{"all" => [yes, no]})
    end

    test "WF-60: earlier step results and the run's timestamps are read, time_add moves a time" do
      assert eval(%{"eq" => [var("steps.mail.delivered"), true]})
      refute eval(%{"eq" => [var("steps.mail.clicked"), true]})
      refute eval(%{"eq" => [var("steps.other.delivered"), true]})

      assert eval(%{
               "gt" => [var("event.time"), %{"time_add" => [var("recipient.joined_at"), "P30D"]}]
             })

      assert eval(%{"eq" => [var("run.started_at"), var("event.time")]})

      assert eval(%{
               "lt" => [%{"time_add" => ["2026-11-01T00:00:00Z", "P1D"]}, var("event.time")]
             })
    end
  end

  describe "WF-60 validation" do
    test "WF-60: a valid condition has no errors and its references are listed" do
      condition = %{
        "all" => [
          %{"eq" => [var("steps.mail.delivered"), true]},
          %{"in" => [var("recipient.plan"), ["gold"]]}
        ]
      }

      assert Condition.validate(condition, @scope) == []
      assert {:step, "mail"} in Condition.references(condition)
      assert {:recipient, "plan"} in Condition.references(condition)
    end

    test "WF-60: an unknown operator, an undeclared attribute and an unknown step are refused" do
      assert [%{code: "unsupported_value"}] =
               Condition.validate(%{"matches" => [var("data.a"), "x"]}, @scope)

      assert [%{pointer: "/eq/0/var", code: "not_found"}] =
               Condition.validate(%{"eq" => [var("recipient.age"), 3]}, @scope)

      assert [%{pointer: "/eq/0/var", code: "not_allowed"}] =
               Condition.validate(%{"eq" => [var("steps.later.delivered"), true]}, @scope)

      assert [%{code: "unsupported_value"}] =
               Condition.validate(%{"eq" => [var("steps.mail.opened"), true]}, @scope)
    end

    test "WF-60: incoming is read only by a match condition" do
      condition = %{"eq" => [var("incoming.answer"), "yes"]}
      assert [%{code: "not_allowed"}] = Condition.validate(condition, @scope)
      assert Condition.validate(condition, Map.put(@scope, :incoming, true)) == []
    end

    test "WF-60: size, depth, node and constant limits hold" do
      deep = Enum.reduce(1..9, %{"eq" => [1, 1]}, fn _n, inner -> %{"not" => inner} end)
      assert [%{code: "too_long"}] = Condition.validate(deep, @scope)

      many = %{"any" => List.duplicate(%{"eq" => [var("data.a"), 1]}, 30)}
      assert [%{code: "too_long"}] = Condition.validate(many, @scope)

      long = %{"eq" => [var("data.a"), String.duplicate("x", 257)]}
      assert [%{code: "too_long"}] = Condition.validate(long, @scope)

      list = %{"in" => [var("data.a"), Enum.to_list(1..101)]}
      assert [%{code: "too_long"}] = Condition.validate(list, @scope)

      big = %{"eq" => [var("data.a"), String.duplicate("y", 250)]}
      huge = %{"any" => List.duplicate(big, 17)}
      assert [%{code: "too_long"}] = Condition.validate(huge, @scope)
    end

    test "AG-14: the same language is exposed for a waitpoint's second-stage match" do
      condition = %{"eq" => [var("incoming.decision"), "approve"]}
      assert Relay.Workflow.validate_condition(condition, Map.put(@scope, :incoming, true)) == []

      assert Relay.Workflow.evaluate_condition(condition, %{incoming: %{"decision" => "approve"}})
    end
  end
end
