defmodule Relay.Delivery.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias Relay.Delivery.RetryPolicy
  alias RelayTest.DeliveryFixture

  {:ok, tenant} = Relay.Id.parse("0192f3a4-5b6c-7d8e-9f01-23456789abcd")
  {:ok, delivery} = Relay.Id.parse("0192f3a4-5b6c-7d8e-9f01-23456789abce")
  @tenant tenant
  @delivery delivery
  @now ~U[2026-10-27 12:00:00.000000Z]

  defp input(fields) do
    Map.merge(
      %{
        tenant_id: @tenant,
        environment: :live,
        delivery_id: @delivery,
        attempt_no: 1,
        state: :failed,
        failure_class: "transient",
        condition: "server_error",
        channel: "push",
        provider: "apns",
        message_class: "transactional",
        retry_after_ms: nil,
        expires_at: nil,
        now: @now,
        parameters: DeliveryFixture.parameters(1),
        budget: :allow
      },
      Map.new(fields)
    )
  end

  defp after_ms(ms), do: DateTime.add(@now, ms, :millisecond)

  describe "T-26 INV-14 classes" do
    test "INV-14: permanent classes are never retried" do
      for class <- ~w(permanent_target permanent_content sender_config) do
        assert RetryPolicy.next(input(failure_class: class)) ==
                 {:dead_letter, :permanent, "retry.permanent"}
      end

      assert RetryPolicy.next(input(failure_class: "policy")) == {:fail, "retry.policy"}

      assert RetryPolicy.next(input(failure_class: "policy", rule_id: "policy.opt_out")) ==
               {:fail, "policy.opt_out"}
    end

    test "T-28: an uncertain attempt is not retried blindly" do
      assert RetryPolicy.next(input(state: :unknown)) == {:no_retry, "retry.uncertain"}
    end

    test "CH-70: a failure without a backoff row is exhausted without a retry" do
      for fields <- [
            [failure_class: "quota", condition: nil],
            [failure_class: "auth", condition: nil],
            [failure_class: "unknown", condition: nil],
            [channel: "sms", provider: nil, condition: "server_error"]
          ] do
        assert RetryPolicy.next(input(fields)) ==
                 {:dead_letter, :exhausted, "channel_parameters.missing"}
      end
    end

    test "T-26: the last allowed attempt is exhausted" do
      assert RetryPolicy.next(input(attempt_no: 5)) ==
               {:dead_letter, :exhausted, "retry.max_attempts"}

      assert {:retry, _, _, 5} = RetryPolicy.next(input(attempt_no: 4))
    end
  end

  describe "T-26 CH-9 backoff" do
    test "T-26, T-30: full jitter backoff follows the J1 and J2 vectors" do
      assert RetryPolicy.next(input(attempt_no: 1)) == {:retry, after_ms(1_796_129), 2, 2}
      assert RetryPolicy.next(input(attempt_no: 3)) == {:retry, after_ms(4_899_221), 8, 4}
    end

    test "CH-9: Retry-After longer than the local backoff wins with its jitter (J3)" do
      assert RetryPolicy.next(
               input(attempt_no: 2, condition: "rate_limited", retry_after_ms: 10_000)
             ) ==
               {:retry, after_ms(11_916), 2, 3}
    end

    test "CH-9: local backoff longer than Retry-After is never shortened" do
      assert RetryPolicy.next(input(attempt_no: 1, retry_after_ms: 10_000)) ==
               {:retry, after_ms(1_796_129), 2, 2}
    end

    test "CH-9: a retry_after row waits the default Retry-After plus jitter" do
      fcm = input(provider: "fcm", condition: "rate_limited")
      {:retry, at, 2, 2} = RetryPolicy.next(fcm)
      wait = DateTime.diff(at, @now, :millisecond)
      assert wait >= 60_000 and wait <= 72_000
    end

    test "T-26: the same delivery and attempt number always plan the same time" do
      assert RetryPolicy.next(input(attempt_no: 2)) == RetryPolicy.next(input(attempt_no: 2))
    end

    test "CH-70, T-26: a security message retries after 1 s with a 15 s cap and 3 attempts on every channel" do
      for channel <- ~w(push email sms whatsapp voice) do
        security = input(channel: channel, message_class: "security", provider: nil)
        {:retry, at, 2, 2} = RetryPolicy.next(security)
        assert DateTime.diff(at, @now, :millisecond) <= 1000
        {:retry, at, 2, 3} = RetryPolicy.next(%{security | attempt_no: 2})
        assert DateTime.diff(at, @now, :millisecond) <= 2000

        assert RetryPolicy.next(%{security | attempt_no: 3}) ==
                 {:dead_letter, :exhausted, "retry.max_attempts"}
      end
    end

    test "T-36: retries are planned at a lower priority than first attempts" do
      assert Enum.map(2..6, &RetryPolicy.priority/1) == [2, 2, 8, 8, 8]
    end
  end

  describe "CH-12 T-27 limits" do
    test "CH-12: a retry that would start at or after expires_at expires instead" do
      assert RetryPolicy.next(input(expires_at: after_ms(1_796_129))) ==
               {:expire, "retry.expires_at"}

      assert {:retry, _, _, _} = RetryPolicy.next(input(expires_at: after_ms(1_796_130)))
    end

    test "T-27: a retry the budget denies goes to the dead letters" do
      assert RetryPolicy.next(input(budget: :deny)) ==
               {:dead_letter, :budget_denied, "retry.budget_denied"}
    end
  end
end
