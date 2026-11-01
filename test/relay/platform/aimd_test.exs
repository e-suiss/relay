defmodule Relay.Platform.AimdTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Platform.Aimd

  @w_max_ms 60_000

  defp mu, do: one_of([integer(1..5_000), float(min: 0.5, max: 5_000.0)])

  defp l_max(mu), do: mu * @w_max_ms / 1_000

  describe "T-97 AIMD ceiling" do
    test "T-97: without a known service rate there is no ceiling" do
      assert Aimd.step(nil, nil) == nil
      assert Aimd.step(10.0, nil) == nil
      assert Aimd.step(10.0, {nil, @w_max_ms, 5}) == nil
      assert Aimd.step(10.0, {0, @w_max_ms, 5}) == nil
    end

    test "T-97: the ceiling starts at μ and the first deep queue halves it" do
      assert Aimd.step(nil, {10, @w_max_ms, 0}) == 10.0
      assert Aimd.step(nil, {10, @w_max_ms, 300}) == 10.0
      assert Aimd.step(nil, {10, @w_max_ms, 481}) == 5.0
    end

    test "T-97: above 0.8 L_max halves, below 0.5 L_max adds 5 % of μ, in between holds" do
      assert Aimd.step(8.0, {10, @w_max_ms, 500}) == 4.0
      assert Aimd.step(4.0, {10, @w_max_ms, 299}) == 4.5
      assert Aimd.step(4.0, {10, @w_max_ms, 300}) == 4.0
      assert Aimd.step(4.0, {10, @w_max_ms, 480}) == 4.0
    end

    test "T-97: repeated pressure stops at 1 % of μ and recovery stops at μ" do
      low = Enum.reduce(1..20, nil, fn _, c -> Aimd.step(c, {10, @w_max_ms, 10_000}) end)
      assert_in_delta low, 0.1, 1.0e-12
      high = Enum.reduce(1..40, low, fn _, c -> Aimd.step(c, {10, @w_max_ms, 0}) end)
      assert high == 10.0
    end

    property "T-97: the ceiling always stays between 1 % of μ and μ" do
      check all mu <- mu(),
                previous <- one_of([constant(nil), float(min: 0.0, max: 20_000.0)]),
                queued <- integer(0..1_000_000) do
        ceiling = Aimd.step(previous, {mu, @w_max_ms, queued})
        assert ceiling >= mu * 0.01 - 1.0e-9
        assert ceiling <= mu + 1.0e-9
      end
    end

    property "T-97: the step halves above the high water mark and adds 5 % of μ below the low one" do
      check all mu <- mu(), share <- float(min: 0.01, max: 1.0) do
        previous = mu * share
        deep = trunc(l_max(mu) * 0.8) + 1
        halved = max(previous * 0.5, mu * 0.01)
        raised = min(previous + mu * 0.05, mu)

        assert_in_delta Aimd.step(previous, {mu, @w_max_ms, deep}), halved, 1.0e-6
        assert_in_delta Aimd.step(previous, {mu, @w_max_ms, 0}), raised, 1.0e-6
      end
    end
  end

  describe "T-97 input under the ceiling" do
    test "T-97: one second of input passes at once, the next waits one emission interval" do
      assert {:allow, tat} = Aimd.admit(2.0, nil, 0)
      assert {:allow, tat} = Aimd.admit(2.0, tat, 0)
      assert {:deny, 500} = Aimd.admit(2.0, tat, 0)
      assert {:allow, _tat} = Aimd.admit(2.0, tat, 500_000)
    end

    test "T-97: a ceiling below one request a second still lets one request through" do
      assert {:allow, tat} = Aimd.admit(0.1, nil, 0)
      assert {:deny, 10_000} = Aimd.admit(0.1, tat, 0)
      assert {:allow, _tat} = Aimd.admit(0.1, tat, 10_000_000)
    end

    property "T-97: within one instant no more than one second of input passes" do
      check all ceiling <- float(min: 0.05, max: 500.0), tries <- integer(1..600) do
        {allowed, _tat} =
          Enum.reduce(1..tries, {0, nil}, fn _, {n, tat} ->
            case Aimd.admit(ceiling, tat, 1_000_000) do
              {:allow, next} -> {n + 1, next}
              {:deny, retry_ms} when retry_ms > 0 -> {n, tat}
            end
          end)

        assert allowed == min(tries, max(trunc(ceiling), 1))
      end
    end
  end
end
