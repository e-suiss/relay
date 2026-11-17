defmodule Relay.Workflow.OtpChainTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Workflow.OtpChain
  alias Relay.Workflow.RouteTree

  @t0 ~U[2026-11-17 10:00:00Z]
  @written ~w(whatsapp sms voice)
  @otp ~w(sms whatsapp voice)
  @any ~w(sms whatsapp voice email)

  defp next(tree, facts, leaves \\ %{}) do
    {:ok, plan} = RouteTree.next(tree, facts, %{now: @t0, leaves: leaves, events: []})
    plan
  end

  defp opened(plan), do: Enum.map(plan.open, & &1.channel)

  defp inputs do
    gen all permitted <- one_of([constant(:all), list_of(member_of(@otp), max_length: 3)]),
            known? <- boolean(),
            unhealthy <- list_of(member_of(@otp), max_length: 3),
            closed <- member_of([[], ["sms"]]),
            sim_changed <- member_of([nil, true, false]),
            app_active <- member_of([nil, true, false]) do
      %{
        permitted: permitted,
        whatsapp_reachable: known?,
        unhealthy: Enum.uniq(unhealthy),
        closed: closed,
        sim_changed: sim_changed,
        mobile_app_active: app_active
      }
    end
  end

  describe "PC-53 the OTP chain is a function of its inputs" do
    test "PC-53: WhatsApp is first only when the recipient's WhatsApp reachability is known" do
      assert OtpChain.order(@written, %{whatsapp_reachable: true}) == ~w(whatsapp sms voice)
      assert OtpChain.order(@written, %{whatsapp_reachable: false}) == ~w(sms whatsapp voice)
      assert OtpChain.order(@written, %{}) == ~w(sms whatsapp voice)
      assert OtpChain.order(~w(sms whatsapp), %{whatsapp_reachable: true}) == ~w(sms whatsapp)
      assert OtpChain.order(~w(whatsapp), %{whatsapp_reachable: false}) == ~w(whatsapp)
    end

    test "PC-53: provider health moves a channel no provider can take behind the others" do
      inputs = %{whatsapp_reachable: true, unhealthy: ["whatsapp"]}
      assert OtpChain.order(@written, inputs) == ~w(sms voice whatsapp)

      assert OtpChain.order(~w(sms voice), %{unhealthy: ["sms"]}) == ~w(voice sms)
      assert OtpChain.order(~w(sms voice), %{unhealthy: ["sms", "voice"]}) == ~w(sms voice)
    end

    test "PC-53, CH-54: SMS closed for the recipient's country gives way to voice" do
      inputs = %{country: "GB", closed: ["sms"]}
      assert OtpChain.order(~w(sms voice), inputs) == ~w(voice sms)
      assert OtpChain.order(~w(sms voice), %{country: "TR", closed: []}) == ~w(sms voice)
    end

    test "PC-53: the same inputs always give the same order" do
      check all inputs <- inputs() do
        assert OtpChain.order(@written, inputs) == OtpChain.order(@written, inputs)
      end
    end

    property "PC-53: WhatsApp never leads a chain of several channels unless its reachability is known" do
      check all inputs <- inputs(), written <- list_of(member_of(@otp), max_length: 4) do
        order = OtpChain.order(written, inputs)

        if length(order) > 1 and not inputs.whatsapp_reachable,
          do: refute(hd(order) == "whatsapp")
      end
    end

    test "PC-53: the frozen inputs of a run give the same order when they are read back" do
      frozen = %{
        "permitted" => ["sms", "whatsapp"],
        "country" => "TR",
        "closed" => [],
        "whatsapp_reachable" => true,
        "unhealthy" => ["sms"],
        "sim_changed" => nil,
        "mobile_app_active" => true
      }

      inputs = OtpChain.thaw(Jason.decode!(Jason.encode!(frozen)))

      assert inputs.permitted == ["sms", "whatsapp"]
      assert inputs.mobile_app_active == true
      assert OtpChain.order(@written, inputs) == ~w(whatsapp sms)
      assert OtpChain.thaw(nil) == nil
      assert OtpChain.thaw(%{}).permitted == :all
    end
  end

  describe "PC-52 INV-23 the chain stays inside the sender's permitted channels" do
    property "PC-52: the chain never names a channel the sender did not permit or the route did not write" do
      check all inputs <- inputs(), written <- list_of(member_of(@any), max_length: 5) do
        order = OtpChain.order(written, inputs)

        assert order -- written == []
        assert order == Enum.uniq(order)

        if is_list(inputs.permitted), do: assert(order -- inputs.permitted == [])
      end
    end

    test "PC-52: a narrowed request keeps the chain in its channels" do
      assert OtpChain.order(@written, %{permitted: ["sms"]}) == ["sms"]
      assert OtpChain.order(@written, %{permitted: []}) == []
      assert OtpChain.order(@written, %{permitted: ["voice", "sms"]}) == ~w(sms voice)
    end

    test "INV-23, PC-51: e-mail is never part of an otp_oob chain" do
      assert OtpChain.channels() == ~w(sms whatsapp voice)
      assert OtpChain.order(~w(email sms push in_app), %{}) == ["sms"]
      assert OtpChain.order(~w(email), %{permitted: ["email"]}) == []
    end
  end

  describe "E-33 the sender's signals are router inputs" do
    test "E-33: after a SIM change the SIM-bound channels follow WhatsApp when its reachability is known" do
      known = %{whatsapp_reachable: true, sim_changed: true}
      assert OtpChain.order(~w(sms voice whatsapp), known) == ~w(whatsapp sms voice)

      unknown = %{whatsapp_reachable: false, sim_changed: true}
      assert OtpChain.order(~w(sms voice whatsapp), unknown) == ~w(sms voice whatsapp)

      unchanged = %{whatsapp_reachable: true, sim_changed: false}
      assert OtpChain.order(~w(sms voice whatsapp), unchanged) == ~w(sms voice whatsapp)
    end

    test "E-33, E-32: the mobile application signal is carried and moves no channel" do
      for active <- [nil, true, false] do
        inputs = %{whatsapp_reachable: true, mobile_app_active: active}
        assert OtpChain.order(@written, inputs) == @written
      end
    end
  end

  describe "PC-53 WF-18 the route follows the chain" do
    @route %{"single" => ["whatsapp", "sms", "voice"]}

    test "PC-53: a single route of an otp_oob run tries the channels in the chain's order" do
      assert opened(next(@route, %{otp: %{whatsapp_reachable: true}})) == ["whatsapp"]
      assert opened(next(@route, %{otp: %{whatsapp_reachable: false}})) == ["sms"]
      assert opened(next(@route, %{otp: %{unhealthy: ["sms"], closed: []}})) == ["voice"]
      assert opened(next(@route, %{})) == ["whatsapp"]
    end

    test "PC-53, WF-15: the fallback follows the chain's order when a channel fails" do
      facts = %{otp: %{whatsapp_reachable: false}}
      failed = %{status: :failed, at: @t0, evidence: []}

      assert opened(next(@route, facts, %{"/single/1" => failed})) == ["whatsapp"]

      leaves = %{"/single/1" => failed, "/single/0" => failed}
      assert opened(next(@route, facts, leaves)) == ["voice"]
    end

    test "PC-53: a pick strategy of an otp_oob run follows the chain too" do
      pick = %{"user_preference" => ["whatsapp", "sms"]}
      assert opened(next(pick, %{otp: %{whatsapp_reachable: false}})) == ["sms"]
      assert opened(next(pick, %{otp: %{whatsapp_reachable: true}})) == ["whatsapp"]
    end

    test "PC-52: a channel outside the permitted set keeps its place behind the chain" do
      facts = %{otp: %{permitted: ["voice"], whatsapp_reachable: true}}
      assert opened(next(@route, facts)) == ["voice"]
    end

    test "WF-18: a route with nested nodes keeps its written order" do
      nested = %{"single" => ["whatsapp", %{"all" => ["sms", "voice"]}]}
      assert opened(next(nested, %{otp: %{whatsapp_reachable: false}})) == ["whatsapp"]
    end
  end
end
