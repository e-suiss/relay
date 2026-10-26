defmodule Relay.Platform.Concurrency.SnoozeTest do
  use ExUnit.Case, async: true

  alias Relay.Platform.Concurrency

  @scope Relay.Scope.new!(
           <<1, 146, 243, 164, 91, 108, 125, 142, 159, 1, 35, 69, 103, 137, 171, 205>>,
           :live
         )

  describe "T-22 T-30 snooze on a full limit" do
    test "T-22: a full limit snoozes for the wait clamped to 1–30 seconds plus up to 20 % jitter" do
      for {wait, range} <- [
            {0, 1..2},
            {500, 1..2},
            {5_000, 5..6},
            {29_000, 29..35},
            {600_000, 30..36}
          ] do
        assert Concurrency.snooze_seconds(@scope, "oban:1", 0, wait) in range, "wait #{wait}"
      end
    end

    test "T-30: the snooze is deterministic for a job and its k-th postponement" do
      a = Concurrency.snooze_seconds(@scope, "oban:7", 3, 20_000)
      assert a == Concurrency.snooze_seconds(@scope, "oban:7", 3, 20_000)

      spread =
        for k <- 0..40, uniq: true, do: Concurrency.snooze_seconds(@scope, "oban:7", k, 20_000)

      assert length(spread) > 1
    end

    test "T-91 (1): the default in-flight limits are 200 per tenant and channel and 1000 per tenant" do
      assert Concurrency.default_limit(:tenant_channel) == 200
      assert Concurrency.default_limit(:tenant_deliveries) == 1_000
      assert Concurrency.lease_ms() == 120_000
      assert Concurrency.renew_ms() == 40_000
    end

    test "T-22: counter keys are the three families with an optional part" do
      for key <- ["cc.tenant_channel:push", "cc.tenant_deliveries", "cc.provider_account:acct_1"],
          do: assert(Concurrency.counter_key?(key))

      for key <- [
            "tenant_deliveries",
            "cc.Bad",
            "cc.x:a:b",
            "cc.x:" <> String.duplicate("a", 129)
          ],
          do: refute(Concurrency.counter_key?(key))
    end
  end
end
