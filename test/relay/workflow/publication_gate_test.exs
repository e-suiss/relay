defmodule Relay.Workflow.PublicationGateTest do
  use ExUnit.Case, async: true

  alias Relay.Workflow.Definition

  @mail %{"type" => "channel", "key" => "mail", "channel" => "email", "template" => "w"}

  defp definition(overrides) do
    Map.merge(
      %{
        "name" => "Reminder",
        "category" => "orders",
        "message_class" => "transactional",
        "event_schema" => %{"type" => "object"},
        "steps" => [@mail]
      },
      overrides
    )
  end

  defp steps(steps, overrides \\ %{}),
    do: Definition.gate(definition(Map.put(overrides, "steps", steps)))

  defp codes(errors), do: errors |> Enum.map(&{&1.pointer, &1.code}) |> Enum.uniq()

  defp condition(key, when_, branch, otherwise \\ nil) do
    step = %{
      "type" => "condition",
      "key" => key,
      "branches" => [%{"when" => when_, "steps" => branch}]
    }

    if otherwise, do: Map.put(step, "else", otherwise), else: step
  end

  defp mail(key), do: %{@mail | "key" => key}

  describe "WF-59 definition format" do
    test "WF-59: every step type, routes, variants, controls and content_dedup are accepted" do
      tree = %{
        "single" => [
          "in_app",
          %{"all" => ["email", %{"channel" => "push", "strategy" => "last_active_device"}]}
        ],
        "trigger" => %{"after_delay" => "PT10M"}
      }

      all = [
        %{
          "type" => "throttle",
          "key" => "limit",
          "throttle_key" => "{{data.user}}",
          "limit" => 3,
          "window" => "PT1H"
        },
        %{
          "type" => "digest",
          "key" => "batch",
          "digest_key" => "{{data.thread}}",
          "mode" => "sliding",
          "debounce" => "PT30S",
          "max_wait" => "PT5M",
          "max_items" => 50,
          "leading" => "none",
          "render" => %{"first" => 5, "last" => 5}
        },
        %{
          "type" => "channel",
          "key" => "routed",
          "route" => tree,
          "template" => "w",
          "digest_template" => "w-digest"
        },
        %{"type" => "channel", "key" => "named", "route" => "default_route", "template" => "w"},
        %{
          "type" => "channel",
          "key" => "ab",
          "channel" => "email",
          "template" => "w",
          "variants" => [
            %{"key" => "a", "weight" => 50, "template" => "w-a"},
            %{"key" => "b", "weight" => 50, "template" => "w-b"}
          ]
        },
        %{"type" => "delay", "key" => "wait", "duration" => "P1D"},
        %{"type" => "delay", "key" => "until", "until" => "/appointment_at"},
        %{
          "type" => "time_window",
          "key" => "office",
          "windows" => [%{"days" => ["mon", "tue"], "start" => "09:00", "end" => "18:00"}]
        },
        %{
          "type" => "wait_for_event",
          "key" => "reply",
          "event_type" => "ticket.replied",
          "correlation_key" => "{{data.ticket}}",
          "match" => %{"eq" => [%{"var" => "incoming.state"}, "open"]},
          "timeout" => "P2D",
          "on_timeout" => [mail("late")]
        },
        condition("check", %{"eq" => [%{"var" => "steps.routed.seen"}, false]}, [mail("again")], [
          mail("other")
        ]),
        %{
          "type" => "webhook",
          "key" => "hook",
          "endpoint" => "crm",
          "event_type" => "order.reminded"
        }
      ]

      extra = %{
        "recipient_attributes" => %{"plan" => "string"},
        "content_dedup" => %{"window" => "PT10M"},
        "controls" => ["/name", "/steps/5/duration"],
        "message_class" => "social"
      }

      assert steps(all, extra) == []
    end

    test "WF-59: the contract schema refuses an unknown field and a step without its fields" do
      assert [_ | _] = steps([Map.put(@mail, "colour", "red")])
      assert [_ | _] = steps([%{"type" => "delay", "key" => "wait"}])

      assert [_ | _] =
               steps([
                 %{
                   "type" => "channel",
                   "key" => "both",
                   "channel" => "email",
                   "route" => "r",
                   "template" => "w"
                 }
               ])

      assert [_ | _] = steps([%{"type" => "fetch", "key" => "load"}])
    end

    test "WF-59: step keys are unique over the whole tree" do
      tree = [mail("mail"), condition("check", %{"eq" => [1, 1]}, [mail("mail")])]
      assert {"/definition/steps/1/branches/0/steps/0/key", "conflict"} in codes(steps(tree))
    end

    test "WF-59: at most 50 steps over the tree and branches nested at most 4 deep" do
      flat = for n <- 1..30, do: mail("m#{n}")
      branched = [condition("c", %{"eq" => [1, 1]}, Enum.map(31..51, &mail("m#{&1}"))) | flat]
      assert {"/definition/steps", "too_long"} in codes(steps(branched))

      nested =
        Enum.reduce(1..5, [mail("leaf")], fn n, inner ->
          [condition("c#{n}", %{"eq" => [1, 1]}, inner)]
        end)

      assert Enum.any?(codes(steps(nested)), &match?({_pointer, "too_long"}, &1))
    end

    test "WF-59: an inline route tree is at most 4 deep with at most 10 leaves" do
      deep = %{
        "single" => [%{"all" => [%{"single" => [%{"all" => [%{"single" => ["email"]}]}]}]}]
      }

      wide = %{
        "all" => [
          %{"all" => ~w(email sms push web_push in_app slack)},
          %{"single" => ~w(teams telegram discord whatsapp voice)}
        ]
      }

      for tree <- [deep, wide] do
        step = %{"type" => "channel", "key" => "r", "route" => tree, "template" => "w"}

        assert Enum.any?(codes(steps([step])), fn {pointer, code} ->
                 code == "too_long" and String.starts_with?(pointer, "/definition/steps/0/route")
               end)
      end
    end
  end

  describe "WF-37 duration ceilings" do
    test "WF-37: delay, digest, throttle and wait ceilings are validation errors" do
      cases = [
        {%{"type" => "delay", "key" => "d", "duration" => "P91D"},
         "/definition/steps/0/duration"},
        {%{
           "type" => "digest",
           "key" => "d",
           "digest_key" => "k",
           "mode" => "fixed",
           "max_wait" => "P32D"
         }, "/definition/steps/0/max_wait"},
        {%{
           "type" => "throttle",
           "key" => "d",
           "throttle_key" => "k",
           "limit" => 1,
           "window" => "P32D"
         }, "/definition/steps/0/window"},
        {%{
           "type" => "wait_for_event",
           "key" => "d",
           "event_type" => "a.b",
           "correlation_key" => "k",
           "timeout" => "P31D"
         }, "/definition/steps/0/timeout"}
      ]

      for {step, pointer} <- cases do
        assert {pointer, "too_long"} in codes(steps([step])), pointer
      end

      assert codes(steps([%{"type" => "delay", "key" => "d", "duration" => "P90D"}])) == []
    end

    test "WF-15: a zero time-based trigger and a zero escalation step are refused" do
      tree = %{"single" => ["push", "email"], "trigger" => %{"after_delay" => "PT0S"}}
      step = %{"type" => "channel", "key" => "r", "route" => tree, "template" => "w"}

      assert [{pointer, "unsupported_value"}] = codes(steps([step]))
      assert String.starts_with?(pointer, "/definition/steps/0/route")
    end

    test "WF-35: the content deduplication window is PT1M to PT24H" do
      assert [{_, "too_short"}] =
               codes(steps([@mail], %{"content_dedup" => %{"window" => "PT30S"}}))

      assert [{_, "too_long"}] = codes(steps([@mail], %{"content_dedup" => %{"window" => "P2D"}}))
    end
  end

  describe "WF-60 conditions in the gate" do
    test "WF-60: a condition may read only earlier steps on its own path and declared attributes" do
      later = [condition("c", %{"eq" => [%{"var" => "steps.mail.delivered"}, true]}, []), @mail]

      assert [{"/definition/steps/0/branches/0/when/eq/0/var", "not_allowed"}] =
               codes(steps(later))

      other =
        [
          condition("c", %{"eq" => [1, 1]}, [mail("inside")]),
          condition("d", %{"eq" => [%{"var" => "steps.inside.delivered"}, true]}, [])
        ]

      assert [{_pointer, "not_allowed"}] = codes(steps(other))

      attribute = [condition("c", %{"eq" => [%{"var" => "recipient.plan"}, "gold"]}, [])]
      assert [{_pointer, "not_found"}] = codes(steps(attribute))
      assert steps(attribute, %{"recipient_attributes" => %{"plan" => "string"}}) == []
    end
  end

  describe "WF-28 WF-18 WF-40 class and subtype rules" do
    test "WF-28: digest steps are refused for the security, transactional and action_required classes" do
      digest = %{
        "type" => "digest",
        "key" => "d",
        "digest_key" => "k",
        "mode" => "fixed",
        "max_wait" => "PT1H"
      }

      for class <- ~w(security transactional action_required) do
        assert [{"/definition/steps/0", "not_allowed"}] =
                 codes(steps([digest, @mail], %{"message_class" => class}))
      end

      assert steps([digest, @mail], %{"message_class" => "social"}) == []
    end

    test "WF-18: an otp_oob workflow sends no e-mail and email_verification sends only e-mail" do
      otp = %{"message_class" => "security", "security_subtype" => "otp_oob"}
      tree = %{"single" => ["sms", "email"]}
      routed = %{"type" => "channel", "key" => "r", "route" => tree, "template" => "w"}

      assert {"/definition/steps/0", "not_allowed"} in codes(steps([routed], otp))
      assert [{"/definition/steps/0", "not_allowed"}] = codes(steps([@mail], otp))
      assert steps([%{@mail | "channel" => "sms"}], otp) == []

      verify = %{"message_class" => "security", "security_subtype" => "email_verification"}
      assert steps([@mail], verify) == []
      assert [{_, "not_allowed"}] = codes(steps([%{@mail | "channel" => "sms"}], verify))
    end

    test "WF-18: named routes are checked against the routes they name" do
      named =
        definition(%{
          "message_class" => "security",
          "security_subtype" => "otp_oob",
          "steps" => [%{"type" => "channel", "key" => "r", "route" => "otp", "template" => "w"}]
        })

      assert [%{code: "not_found"}] = Definition.named_route_errors(named, %{})

      assert [%{code: "not_allowed"}] =
               Definition.named_route_errors(named, %{"otp" => ["sms", "email"]})

      assert Definition.named_route_errors(named, %{"otp" => ["sms", "voice"]}) == []
    end

    test "WF-63: a security workflow has no delay, time window or digest step" do
      security = %{"message_class" => "security"}
      delay = %{"type" => "delay", "key" => "d", "duration" => "PT1M"}

      window = %{
        "type" => "time_window",
        "key" => "w",
        "windows" => [%{"days" => ["mon"], "start" => "09:00", "end" => "17:00"}]
      }

      for step <- [delay, window] do
        assert [{"/definition/steps/0", "not_allowed"}] = codes(steps([step, @mail], security))
        assert steps([step, @mail]) == []
      end
    end

    test "WF-40: an otp_oob workflow is never delayed or digested" do
      otp = %{"message_class" => "security", "security_subtype" => "otp_oob"}
      delay = %{"type" => "delay", "key" => "d", "duration" => "PT1M"}
      sms = %{@mail | "channel" => "sms"}
      assert [{"/definition/steps/0", "not_allowed"}] = codes(steps([delay, sms], otp))
    end
  end

  describe "WF-4 controls" do
    test "WF-4: a control names a text, duration or number field, never structure" do
      delay = %{"type" => "delay", "key" => "wait", "duration" => "PT1H"}

      assert steps([delay, @mail], %{"controls" => ["/steps/0/duration", "/description"]})
             |> Enum.map(& &1.code) == ["not_allowed"]

      assert steps([delay, @mail], %{"controls" => ["/steps/0/duration"]}) == []

      assert [{_, "not_allowed"}] =
               codes(steps([delay, @mail], %{"controls" => ["/steps/0/key"]}))

      assert [{_, "not_allowed"}] = codes(steps([delay, @mail], %{"controls" => ["/steps"]}))
    end
  end

  describe "WF-6 Mermaid export" do
    test "WF-6: a definition exports as a flowchart with labelled branches joining the next step" do
      tree = [
        mail("first"),
        condition("check", %{"eq" => [1, 1]}, [mail("yes")], [mail("no")]),
        %{"type" => "delay", "key" => "wait", "duration" => "PT1H"},
        mail("last")
      ]

      chart = Definition.mermaid(definition(%{"steps" => tree}))

      assert String.starts_with?(chart, "flowchart TD\n")
      assert chart =~ "start --> s_first"
      assert chart =~ "s_first --> s_check"
      assert chart =~ "s_check -->|branch 1| s_yes"
      assert chart =~ "s_check -->|else| s_no"
      assert chart =~ "s_yes --> s_wait"
      assert chart =~ "s_no --> s_wait"
      assert chart =~ "s_wait --> s_last"
      assert chart =~ "s_last --> finish"
    end
  end
end
