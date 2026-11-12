defmodule Relay.Workflow.RouteTreeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Workflow.RouteTree

  @t0 ~U[2026-11-12 10:00:00Z]
  @channels ~w(push email sms in_app whatsapp)
  @statuses [:pending, :transient, :unknown, :delivered, :failed, :exhausted, :skipped]
  @seen [%{signal: :seen, decision_grade: :reliable}]
  @human_click [%{signal: :clicked, decision_grade: :reliable, actor: :human}]

  @ladder %{
    "escalate" => %{
      "unless" => "seen",
      "ladder" => [
        %{"after" => "PT10M", "node" => "in_app"},
        %{"after" => "PT1H", "node" => "push"},
        %{"after" => "PT1H", "node" => "email"}
      ]
    }
  }

  @in_app "/escalate/ladder/0/node"
  @push "/escalate/ladder/1/node"
  @email "/escalate/ladder/2/node"

  defp at(minutes), do: DateTime.add(@t0, minutes * 60_000, :millisecond)

  defp next(tree, facts \\ %{}, leaves \\ %{}, now \\ @t0, events \\ []) do
    {:ok, plan} = RouteTree.next(tree, facts, %{now: now, leaves: leaves, events: events})
    plan
  end

  defp opened(plan), do: Enum.map(plan.open, & &1.at)
  defp skipped(plan), do: Enum.map(plan.skip, &{&1.at, &1.rule_id})

  defp leaf(status, minutes \\ 0, evidence \\ []),
    do: %{status: status, at: at(minutes), evidence: evidence}

  defp errors(tree, opts \\ []) do
    {:error, errors} = RouteTree.validate(tree, Keyword.put_new(opts, :pointer, "/tree"))
    Enum.map(errors, &{&1.pointer, &1.code})
  end

  defp nest(node, 0), do: node
  defp nest(node, n), do: nest(%{"single" => [node]}, n - 1)

  defp ladder(condition, extra \\ %{}) do
    escalate = @ladder["escalate"] |> Map.put("unless", condition) |> Map.merge(extra)
    %{"escalate" => escalate}
  end

  defp steps(steps), do: put_in(@ladder, ["escalate", "ladder"], steps)

  describe "WF-59 validation" do
    test "WF-13, WF-59: the example tree and every node kind are valid" do
      assert RouteTree.validate(%{"single" => ["in_app", %{"all" => ["push", "email"]}]}) == :ok
      assert RouteTree.validate("email") == :ok
      assert RouteTree.validate(%{"channel" => "push", "strategy" => "last_active_device"}) == :ok
      assert RouteTree.validate(%{"last_active" => ["push", "email"]}) == :ok
      assert RouteTree.validate(%{"user_preference" => ["sms", "email"]}) == :ok
      assert RouteTree.validate(@ladder) == :ok

      delayed = %{"single" => ["push", "email"], "trigger" => %{"after_delay" => "PT10M"}}
      assert RouteTree.validate(delayed) == :ok
      assert RouteTree.validate(%{"single" => ["push"], "trigger" => "on_failure"}) == :ok
    end

    test "WF-15: a time trigger or an escalation step of zero is refused" do
      zero = %{"single" => ["push", "email"], "trigger" => %{"after_delay" => "PT0S"}}
      assert errors(zero) == [{"/tree/trigger/after_delay", "unsupported_value"}]

      step = steps([%{"after" => "P0D", "node" => "push"}])
      assert errors(step) == [{"/tree/escalate/ladder/0/after", "unsupported_value"}]

      vague = %{"single" => ["push"], "trigger" => %{"after_delay" => "soon"}}
      assert errors(vague) == [{"/tree/trigger/after_delay", "invalid_format"}]
    end

    test "WF-59: a tree is at most four levels deep with its leaves and names ten channels" do
      deep = "/tree/single/0/single/0/single/0/single/0"
      assert RouteTree.validate(nest("email", 3)) == :ok
      assert errors(nest("email", 4)) == [{deep, "too_long"}]

      assert RouteTree.validate(%{"all" => List.duplicate("email", 10)}) == :ok
      assert errors(%{"all" => List.duplicate("email", 11)}) == [{"/tree", "too_long"}]
    end

    test "WF-13, WF-17: shapes, channels and strategies outside the format are field errors" do
      assert errors(%{"all" => ["fax"]}) == [{"/tree/all/0", "unsupported_value"}]
      assert errors(%{"all" => []}) == [{"/tree/all", "too_short"}]
      assert errors(%{"any" => ["email"]}) == [{"/tree", "invalid_format"}]
      triggered = %{"all" => ["sms"], "trigger" => "on_failure"}
      assert errors(triggered) == [{"/tree", "invalid_format"}]
      assert errors(%{"last_active" => ["push", "push"]}) == [{"/tree/last_active", "conflict"}]

      device = %{"channel" => "email", "strategy" => "last_active_device"}
      assert errors(device) == [{"/tree/channel", "not_allowed"}]

      newest = %{"channel" => "push", "strategy" => "newest"}
      assert errors(newest) == [{"/tree/strategy", "unsupported_value"}]
    end

    test "WF-21: the stop condition is one of four and only an event names an event type" do
      assert errors(ladder("glanced")) == [{"/tree/escalate/unless", "unsupported_value"}]
      assert errors(ladder("event")) == [{"/tree/escalate/event_type", "required"}]
      assert RouteTree.validate(ladder("event", %{"event_type" => "order.paid"})) == :ok

      typed = ladder("seen", %{"event_type" => "order.paid"})
      assert errors(typed) == [{"/tree/escalate/event_type", "not_allowed"}]
      assert errors(steps([])) == [{"/tree/escalate/ladder", "too_short"}]
    end

    test "WF-18: an otp_oob route never names email and an email_verification route only email" do
      tree = %{"single" => ["sms", "email"]}
      assert errors(tree, security_subtype: "otp_oob") == [{"/tree/single/1", "not_allowed"}]

      otp = %{"single" => ["sms", "whatsapp"]}
      assert RouteTree.validate(otp, security_subtype: "otp_oob") == :ok

      verification = errors(tree, security_subtype: "email_verification")
      assert verification == [{"/tree/single/0", "not_allowed"}]
      assert RouteTree.validate("email", security_subtype: "email_verification") == :ok
    end

    test "IN-55: an otp_oob route never names the inbox" do
      tree = %{"single" => ["sms", "in_app"]}
      assert errors(tree, security_subtype: "otp_oob") == [{"/tree/single/1", "not_allowed"}]
      assert RouteTree.validate(tree) == :ok
    end

    test "WF-13: the channels and the leaf pointers of a tree are in written order" do
      tree = %{"single" => ["in_app", %{"all" => ["push", "email"]}, "email"]}
      assert RouteTree.channels(tree) == ["in_app", "push", "email"]

      assert RouteTree.leaf_pointers(tree) == [
               {"/single/0", "in_app"},
               {"/single/1/all/0", "push"},
               {"/single/1/all/1", "email"},
               {"/single/2", "email"}
             ]

      assert Enum.map(RouteTree.leaf_pointers(@ladder), &elem(&1, 0)) == [@in_app, @push, @email]
      assert RouteTree.channels(%{"all" => []}) == []
    end
  end

  describe "WF-15 single" do
    @chain %{"single" => ["in_app", "email"]}

    test "WF-15: the first node opens alone and the route runs" do
      plan = next(@chain)
      assert opened(plan) == ["/single/0"]
      assert plan.status == :running
      assert plan.wake_at == nil
    end

    test "WF-15, DS-21: a transient failure and an unknown outcome never move the chain" do
      for status <- [:pending, :transient, :unknown] do
        plan = next(@chain, %{}, %{"/single/0" => leaf(status)})
        assert plan.open == [], inspect(status)
        assert plan.status == :running
      end
    end

    test "WF-15: a permanent failure or an exhausted retry budget opens the next node" do
      for status <- [:failed, :exhausted] do
        assert opened(next(@chain, %{}, %{"/single/0" => leaf(status)})) == ["/single/1"]
      end
    end

    test "WF-15: a delivered node ends the chain and every node failing exhausts the route" do
      delivered = %{"/single/0" => leaf(:delivered)}
      assert %{status: :delivered, open: []} = next(@chain, %{}, delivered)

      leaves = %{"/single/0" => leaf(:failed), "/single/1" => leaf(:exhausted)}
      assert %{status: :exhausted, rule_id: "route.exhausted"} = next(@chain, %{}, leaves)
    end

    test "WF-15: after_delay also moves on when the node is not delivered in time" do
      tree = %{"single" => ["push", "email"], "trigger" => %{"after_delay" => "PT10M"}}
      leaves = %{"/single/0" => leaf(:pending)}

      early = next(tree, %{}, leaves, at(5))
      assert early.open == []
      assert early.wake_at == at(10)

      assert opened(next(tree, %{}, leaves, at(10))) == ["/single/1"]
      assert next(tree, %{}, %{"/single/0" => leaf(:delivered)}, at(10)).open == []
    end

    test "WF-13: all opens every node and is delivered once one is" do
      tree = %{"all" => ["push", "email"]}
      assert opened(next(tree)) == ["/all/0", "/all/1"]

      leaves = %{"/all/0" => leaf(:delivered), "/all/1" => leaf(:failed)}
      assert next(tree, %{}, leaves).status == :delivered
    end
  end

  describe "WF-16 PC-10 skips" do
    test "WF-16: a channel without a template variant is skipped and the next one opens" do
      plan = next(@chain, %{variants: ["email"]})
      assert skipped(plan) == [{"/single/0", "template.variant_missing"}]
      assert opened(plan) == ["/single/1"]
    end

    test "PC-10: a channel the locked category's gate refuses is skipped for the next one" do
      plan = next(%{"single" => ["push", "sms"]}, %{locked: ["push"]})
      assert skipped(plan) == [{"/single/0", "route.channel_locked"}]
      assert opened(plan) == ["/single/1"]
    end

    test "WF-15: a channel without an address is skipped; with none left the route ends" do
      plan = next(%{"single" => ["sms", "email"]}, %{reachable: ["email"]})
      assert skipped(plan) == [{"/single/0", "channel.no_address"}]
      assert opened(plan) == ["/single/1"]

      assert %{status: :exhausted, open: []} = next("sms", %{reachable: []})
    end

    test "WF-18, PC-10: an otp_oob route never falls back to email or push at run time" do
      plan = next(%{"single" => ["push", "email", "sms"]}, %{security_subtype: "otp_oob"})

      assert skipped(plan) == [
               {"/single/0", "channel_policy.otp_channel_forbidden"},
               {"/single/1", "channel_policy.otp_channel_forbidden"}
             ]

      assert opened(plan) == ["/single/2"]

      facts = %{security_subtype: "email_verification"}
      verification = next(%{"single" => ["sms", "email"]}, facts)
      assert skipped(verification) == [{"/single/0", "channel_policy.email_verification_only"}]
    end

    test "WF-16: a skip already recorded is not recorded again" do
      plan = next(@chain, %{variants: ["email"]}, %{"/single/0" => leaf(:skipped)})
      assert plan.skip == []
      assert opened(plan) == ["/single/1"]
    end
  end

  describe "WF-13 WF-17 strategies" do
    @last_active %{"last_active" => ["push", "email"]}

    test "WF-13: last_active picks the last active channel, else the list order" do
      assert opened(next(@last_active, %{last_active_channel: "email"})) == ["/last_active/1"]
      assert opened(next(@last_active)) == ["/last_active/0"]
      assert opened(next(@last_active, %{last_active_channel: "sms"})) == ["/last_active/0"]

      plan = next(@last_active, %{last_active_channel: "email", reachable: ["push"]})
      assert skipped(plan) == [{"/last_active/1", "channel.no_address"}]
      assert opened(plan) == ["/last_active/0"]
    end

    test "WF-13: user_preference picks the most preferred channel of the list" do
      tree = %{"user_preference" => ["email", "sms", "push"]}
      facts = %{preferred_channels: ["whatsapp", "sms", "email"]}
      assert opened(next(tree, facts)) == ["/user_preference/1"]
      assert opened(next(tree)) == ["/user_preference/0"]
    end

    test "WF-13: the chosen channel stays chosen and its permanent failure fails the node" do
      facts = %{last_active_channel: "push"}
      assert next(@last_active, facts, %{"/last_active/1" => leaf(:pending)}).open == []

      failed = %{"/last_active/1" => leaf(:failed)}
      assert next(@last_active, facts, failed).status == :exhausted

      chain = %{"single" => [@last_active, "sms"]}
      leaves = %{"/single/0/last_active/1" => leaf(:failed)}
      assert opened(next(chain, %{}, leaves)) == ["/single/1"]
    end

    test "WF-17: last_active_device sends to the last active device, else to every device" do
      tree = %{"channel" => "push", "strategy" => "last_active_device"}
      facts = %{last_active_device: "dev_1"}
      assert [%{at: "", device: {:device, "dev_1"}}] = next(tree, facts).open
      assert [%{device: :all}] = next(tree).open
      assert [%{device: :all}] = next("push", facts).open
    end
  end

  describe "WF-21 WF-22 escalation" do
    test "WF-21: the first step opens at once and the next one after its wait" do
      first = next(@ladder)
      assert opened(first) == [@in_app]
      assert first.wake_at == at(10)

      leaves = %{@in_app => leaf(:delivered)}
      assert %{open: [], wake_at: wake} = next(@ladder, %{}, leaves, at(5))
      assert wake == at(10)

      second = next(@ladder, %{}, leaves, at(10))
      assert opened(second) == [@push]
      assert second.wake_at == at(70)

      leaves = Map.put(leaves, @push, leaf(:delivered, 10))
      assert opened(next(@ladder, %{}, leaves, at(70))) == [@email]
    end

    test "WF-21: a failed step moves on at once and the ladder ends after its last wait" do
      assert opened(next(@ladder, %{}, %{@in_app => leaf(:failed)}, at(1))) == [@push]

      leaves = %{
        @in_app => leaf(:delivered),
        @push => leaf(:delivered, 10),
        @email => leaf(:delivered, 70)
      }

      assert %{status: :running, wake_at: wake} = next(@ladder, %{}, leaves, at(80))
      assert wake == at(130)
      assert %{status: :delivered, wake_at: nil} = next(@ladder, %{}, leaves, at(130))
    end

    test "WF-22, DS-10: reliable seen evidence stops the remaining steps" do
      plan = next(@ladder, %{}, %{@in_app => leaf(:delivered, 0, @seen)}, at(10))

      assert plan.open == []
      assert plan.status == :stopped
      assert [%{at: "", rule_id: "escalation.stopped", signal: :seen}] = plan.stopped
    end

    test "WF-22: read and clicked also meet seen, and clicked meets read" do
      read = [%{signal: :read, decision_grade: :reliable}]
      reading = %{@in_app => leaf(:delivered, 0, read)}
      assert next(@ladder, %{}, reading, at(10)).status == :stopped

      clicked = %{@in_app => leaf(:delivered, 0, @human_click)}
      assert next(ladder("read"), %{}, clicked, at(10)).status == :stopped

      seen = %{@in_app => leaf(:delivered, 0, @seen)}
      assert opened(next(ladder("clicked"), %{}, seen, at(10))) == [@push]
    end

    test "WF-22, DS-31: an open, a likely bot click or unreliable evidence never stops it" do
      for evidence <- [
            %{signal: :opened, decision_grade: :reliable},
            %{signal: :opened, decision_grade: :unreliable},
            %{signal: :clicked, decision_grade: :unreliable, actor: :likely_bot},
            %{signal: :clicked, decision_grade: :reliable, actor: :likely_bot},
            %{signal: :clicked, decision_grade: :reliable},
            %{signal: :seen, decision_grade: :unreliable}
          ] do
        leaves = %{@in_app => leaf(:delivered, 0, [evidence])}
        assert opened(next(ladder("clicked"), %{}, leaves, at(10))) == [@push], inspect(evidence)
      end

      human = %{@in_app => leaf(:delivered, 0, @human_click)}
      assert next(ladder("clicked"), %{}, human, at(10)).status == :stopped
    end

    test "DS-21: the timers run when the outcome is unknown" do
      assert opened(next(@ladder, %{}, %{@in_app => leaf(:unknown)}, at(10))) == [@push]
    end

    test "WF-21: the customer's event stops it only when it comes after the escalation began" do
      tree = ladder("event", %{"event_type" => "order.paid"})
      leaves = %{@in_app => leaf(:delivered)}

      plan = next(tree, %{}, leaves, at(10), [%{type: "order.paid", at: at(3)}])
      assert [%{signal: :event}] = plan.stopped

      early = next(tree, %{}, leaves, at(10), [%{type: "order.paid", at: at(-1)}])
      assert opened(early) == [@push]

      other = next(tree, %{}, leaves, at(10), [%{type: "order.shipped", at: at(3)}])
      assert opened(other) == [@push]
    end

    test "WF-21: a stopped escalation inside a chain ends the chain" do
      tree = %{"single" => [@ladder, "sms"]}
      pointer = "/single/0" <> @in_app
      leaves = %{pointer => leaf(:delivered, 0, @seen)}
      assert %{status: :stopped, open: []} = next(tree, %{}, leaves, at(30))
    end
  end

  describe "WF-13 properties" do
    defp channel, do: member_of(@channels)

    defp node_of(0), do: channel()

    defp node_of(depth) do
      children = list_of(node_of(depth - 1), min_length: 1, max_length: 2)

      one_of([
        channel(),
        map(children, &%{"single" => &1}),
        map(children, &%{"single" => &1, "trigger" => %{"after_delay" => "PT5M"}}),
        map(children, &%{"all" => &1}),
        map(uniq_list_of(channel(), min_length: 1, max_length: 2), &%{"last_active" => &1}),
        map(children, &escalation/1)
      ])
    end

    defp escalation(nodes) do
      ladder = Enum.map(nodes, &%{"after" => "PT10M", "node" => &1})
      %{"escalate" => %{"unless" => "seen", "ladder" => ladder}}
    end

    defp states(tree) do
      pointers = Enum.map(RouteTree.leaf_pointers(tree), &elem(&1, 0))
      statuses = list_of(one_of([constant(nil), member_of(@statuses)]), length: length(pointers))

      bind(statuses, fn statuses ->
        leaves =
          for {pointer, status} <- Enum.zip(pointers, statuses),
              status != nil,
              into: %{},
              do: {pointer, leaf(status)}

        map(integer(0..120), &{tree, leaves, at(&1)})
      end)
    end

    defp cases, do: bind(node_of(3), &states/1)

    defp with_status(leaves, from, to) do
      Map.new(leaves, fn {pointer, leaf} ->
        if leaf.status in from, do: {pointer, %{leaf | status: to}}, else: {pointer, leaf}
      end)
    end

    property "WF-13, WF-59: a plan is deterministic and never reopens a leaf" do
      check all {tree, leaves, now} <- cases(), max_runs: 300 do
        assert RouteTree.validate(tree) == :ok
        plan = next(tree, %{}, leaves, now)
        assert plan == next(tree, %{}, leaves, now)

        pointers = MapSet.new(RouteTree.leaf_pointers(tree), &elem(&1, 0))
        touched = opened(plan) ++ Enum.map(plan.skip, & &1.at)

        assert Enum.uniq(touched) == touched
        assert Enum.all?(touched, &MapSet.member?(pointers, &1))
        refute Enum.any?(touched, &Map.has_key?(leaves, &1))
        assert plan.wake_at == nil or DateTime.compare(plan.wake_at, now) == :gt
      end
    end

    property "WF-15, DS-21: a transient or unknown outcome plans exactly as a pending one" do
      check all {tree, leaves, now} <- cases(),
                status <- member_of([:transient, :unknown]),
                max_runs: 300 do
        pending = with_status(leaves, [:transient, :unknown], :pending)
        other = with_status(pending, [:pending], status)
        assert next(tree, %{}, pending, now) == next(tree, %{}, other, now)
      end
    end

    property "WF-22: open pixel and likely bot evidence never change a plan" do
      noise = [
        %{signal: :opened, decision_grade: :reliable},
        %{signal: :clicked, decision_grade: :unreliable, actor: :likely_bot}
      ]

      check all {tree, leaves, now} <- cases(), max_runs: 300 do
        noisy = Map.new(leaves, fn {pointer, leaf} -> {pointer, %{leaf | evidence: noise}} end)
        assert next(tree, %{}, leaves, now) == next(tree, %{}, noisy, now)
      end
    end
  end
end
