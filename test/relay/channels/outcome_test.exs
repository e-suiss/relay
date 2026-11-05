defmodule Relay.Channels.OutcomeTest do
  use ExUnit.Case, async: true

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Ambiguity
  alias Relay.Channels.Outcome

  defp declarations do
    {:ok, content} = ChannelDeclarations.compose()
    ChannelDeclarations.new(content, nil)
  end

  describe "CH-7 CH-8 normalization" do
    test "CH-7: a mapped provider code takes the class, condition and event code of its mapping" do
      d = declarations()
      raw = %{code: "rate_limited", status: 429, retry_after_ms: 30_000}

      assert {:ok, %Outcome{} = outcome} = Outcome.normalize(d, "fake", "sms", {:rejected, raw})
      assert outcome.state == :failed
      assert outcome.failure_class == "transient"
      assert outcome.condition == "rate_limited"
      assert outcome.raw_code == "rate_limited"
      assert outcome.retry_after_ms == 30_000
      assert outcome.event_code == "rejected"
      refute outcome.unknown_code?

      assert {:ok, %Outcome{failure_class: "permanent_target", event_code: "unregistered"}} =
               Outcome.normalize(d, "fake", "push", {:rejected, %{code: "unregistered"}})
    end

    test "CH-8, INV-46: a code without a mapping is unknown with the raw code kept, never guessed" do
      d = declarations()
      assert {:ok, outcome} = Outcome.normalize(d, "fake", "email", {:rejected, %{code: "X-42"}})
      assert outcome.failure_class == "unknown"
      assert outcome.unknown_code?
      assert outcome.raw_code == "X-42"
      assert Outcome.actions("unknown").alarm
    end

    test "CH-8: a provider success for a suppressed recipient is normalized apart" do
      content = %{
        "semantics" => [],
        "providers" => [
          %{
            "provider" => "esp",
            "channels" => ["email"],
            "evidence" => [%{"channel" => "email", "event_code" => "rejected"}],
            "errors" => [
              %{
                "code" => "suppressed",
                "class" => "policy",
                "condition" => "provider_suppressed",
                "event_code" => "rejected",
                "suppressed_success" => true
              }
            ]
          }
        ]
      }

      d = ChannelDeclarations.new(content, nil)

      assert {:ok, %Outcome{suppressed?: true, failure_class: "policy"}} =
               Outcome.normalize(d, "esp", "email", {:rejected, %{code: "suppressed"}})
    end

    test "CH-10, T-28: no connection is a transient failure and no answer is uncertain" do
      d = declarations()

      assert {:ok, %Outcome{state: :failed, failure_class: "transient", raw_code: raw}} =
               Outcome.normalize(d, "fake", "sms", {:not_sent, "econnrefused"})

      assert raw == "transport:econnrefused"

      assert {:ok, %Outcome{state: :unknown, event_code: "uncertain", condition: "timeout"}} =
               Outcome.normalize(d, "fake", "sms", {:uncertain, "timeout"})
    end

    test "CH-7, DS-13: an acceptance succeeds at the accepted rank unless the adapter says more" do
      d = declarations()
      accepted = {:accepted, %{provider_message_id: "m1"}}

      assert {:ok, %Outcome{state: :succeeded} = outcome} =
               Outcome.normalize(d, "fake", "push", accepted)

      assert outcome.delivery_rank == :accepted
      assert outcome.provider_message_id == "m1"
    end

    test "DS-10: an outcome on a channel without the evidence row is refused" do
      d = declarations()

      assert {:error, :unknown_event} =
               Outcome.normalize(d, "fake", "in_app", {:accepted, %{}})

      assert {:error, :unknown_event} =
               Outcome.normalize(d, "nobody", "sms", {:accepted, %{}})
    end
  end

  describe "CH-7 INV-14 class actions" do
    test "CH-7, INV-14, CH-11: retry, fallback and target cleanup come from the class only" do
      expected = Relay.ChannelParameters.permanent_classes() ++ ~w(transient quota auth unknown)
      assert Enum.sort(Outcome.classes()) == Enum.sort(expected)

      for class <- ~w(permanent_target permanent_content policy sender_config) do
        assert Outcome.actions(class).retry == :never, class
        assert Outcome.actions(class).fallback, class
      end

      assert %{target: :disable, suppress_subscriber: false} = Outcome.actions("permanent_target")
      assert %{target: :keep, suppress_subscriber: false} = Outcome.actions("sender_config")
      assert %{target: :preference, suppress_subscriber: true} = Outcome.actions("policy")
      assert %{retry: :backoff, fallback: false} = Outcome.actions("transient")
      assert %{retry: :until_quota} = Outcome.actions("quota")
      assert %{retry: :after_refresh} = Outcome.actions("auth")
    end
  end

  describe "T-28 uncertain outcome" do
    test "T-28, CH-10, INV-13: the declared policy decides; a provider key retries with the same key" do
      key = %{"mode" => "no_auto_retry", "provider_key" => true}
      assert Ambiguity.decide(key, false, false) == {:retry, :none}
      assert Ambiguity.decide(%{"mode" => "wait_and_query"}, false, false) == :query

      assert Ambiguity.decide(%{"mode" => "retry_accepting_duplicate_risk"}, false, true) ==
               {:retry, :none}

      assert Ambiguity.decide(%{"mode" => "no_auto_retry"}, false, false) == {:stop, :none}
    end

    test "T-28, INV-9: a paid channel retries at most once and marks the delivery uncertain" do
      risk = %{"mode" => "retry_accepting_duplicate_risk"}
      assert Ambiguity.decide(risk, true, false) == {:retry, :uncertain}
      assert Ambiguity.decide(risk, true, true) == {:stop, :uncertain}
      assert Ambiguity.decide(%{"provider_key" => true}, true, true) == {:stop, :uncertain}
      assert Ambiguity.decide(%{"mode" => "no_auto_retry"}, true, false) == {:stop, :uncertain}
    end

    test "T-28: the status query answers, permits a resend of an unreceived request or leaves it unknown" do
      accepted = {:accepted, %{}}
      assert Ambiguity.after_query(accepted, true, false) == {:outcome, accepted}
      assert Ambiguity.after_query(:not_received, false, true) == {:retry, :none}
      assert Ambiguity.after_query(:not_received, true, true) == {:stop, :uncertain}
      assert Ambiguity.after_query(:unavailable, false, false) == {:stop, :none}
    end
  end
end
