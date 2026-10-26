defmodule Relay.Platform.AdmissionTest do
  use ExUnit.Case, async: true

  alias Relay.Platform.Admission

  @classes [
    :security,
    :transactional,
    :action_required,
    :operational,
    :system,
    :social,
    :marketing
  ]

  defp input(class, shed, extra \\ %{}) do
    Map.merge(
      %{
        message_class: class,
        channels: [:email],
        shed: shed,
        breaker_open: MapSet.new(),
        lane_capacity: nil
      },
      extra
    )
  end

  defp shed_combinations,
    do:
      for(
        l1 <- [false, true],
        l2 <- [false, true],
        l3 <- [false, true],
        do: %{l1: l1, l2: l2, l3: l3}
      )

  defp expected(class, shed) do
    case Relay.Platform.Lane.of(class) do
      :l2 when shed.l2 ->
        {:reject, %{status: 503, retry_after_s: 60, rule_id: "admission.overload.l2"}}

      :l3 when shed.l3 ->
        {:reject, %{status: 503, retry_after_s: 1_800, rule_id: "admission.overload.l3"}}

      _lane ->
        :admit
    end
  end

  describe "API-51 T-35 T-92 INV-24 admission control" do
    test "API-51: every class under every load shedding combination follows the table" do
      for class <- @classes, shed <- shed_combinations() do
        assert Admission.decide(input(class, shed)) == expected(class, shed),
               "#{class} #{inspect(shed)}"
      end
    end

    test "INV-24: security is admitted under every shedding combination, every open breaker and every capacity" do
      for shed <- shed_combinations() do
        extra = %{
          breaker_open: MapSet.new([:sms, :email]),
          channels: [:sms],
          lane_capacity: %{l0: {0, 1, 1_000_000}}
        }

        assert Admission.decide(input(:security, shed, extra)) == :admit
      end
    end

    test "T-92: overload answers 503, never 429" do
      for class <- [:operational, :marketing] do
        assert {:reject, %{status: 503}} =
                 Admission.decide(input(class, %{l1: true, l2: true, l3: true}))
      end
    end

    test "API-51: an l1 message is admitted while l1 sheds and postponed in the queue instead" do
      for class <- [:transactional, :action_required] do
        assert Admission.decide(input(class, %{l1: true, l2: true, l3: true})) == :admit
      end
    end

    test "T-35 (1): marketing is refused when every requested channel has all its breakers open" do
      shed = %{l1: false, l2: false, l3: false}

      extra = %{
        channels: [:email, :sms],
        breaker_open: MapSet.new([:email, :sms]),
        breaker_remaining_ms: %{email: 12_400, sms: 30_000}
      }

      assert Admission.decide(input(:marketing, shed, extra)) ==
               {:reject, %{status: 503, retry_after_s: 13, rule_id: "admission.breaker_open"}}

      assert Admission.decide(
               input(:marketing, shed, %{extra | breaker_open: MapSet.new([:email])})
             ) ==
               :admit

      assert {:reject, %{retry_after_s: 1}} =
               Admission.decide(input(:marketing, shed, Map.delete(extra, :breaker_remaining_ms)))

      assert Admission.decide(input(:marketing, shed, %{extra | channels: []})) == :admit
      assert Admission.decide(input(:operational, shed, extra)) == :admit
    end

    test "T-35 (2): a bulk lane refuses the job that would break its target wait, L_max = mu * W_max" do
      shed = %{l1: false, l2: false, l3: false}
      capacity = %{lane_capacity: %{l2: {10, 60_000, 599}, l3: {1, 1_800_000, 1_800}}}

      assert Admission.decide(input(:social, shed, capacity)) == :admit

      assert Admission.decide(
               input(:social, shed, put_in(capacity.lane_capacity.l2, {10, 60_000, 600}))
             ) ==
               {:reject, %{status: 503, retry_after_s: 60, rule_id: "admission.lmax.l2"}}

      assert Admission.decide(input(:marketing, shed, capacity)) ==
               {:reject, %{status: 503, retry_after_s: 1_800, rule_id: "admission.lmax.l3"}}

      assert Admission.decide(input(:marketing, shed, %{lane_capacity: %{l3: nil}})) == :admit

      assert Admission.decide(
               input(:transactional, shed, %{lane_capacity: %{l1: {1, 1_000, 1_000_000}}})
             ) == :admit
    end

    test "API-51: the rule order puts lane shedding before breakers and capacity" do
      extra = %{
        channels: [:email],
        breaker_open: MapSet.new([:email]),
        lane_capacity: %{l3: {1, 1_000, 1_000}}
      }

      assert {:reject, %{rule_id: "admission.overload.l3"}} =
               Admission.decide(input(:marketing, %{l1: false, l2: false, l3: true}, extra))

      assert {:reject, %{rule_id: "admission.breaker_open"}} =
               Admission.decide(input(:marketing, %{l1: false, l2: false, l3: false}, extra))
    end
  end
end
