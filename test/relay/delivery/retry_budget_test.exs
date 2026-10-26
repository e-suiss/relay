defmodule Relay.Delivery.RetryBudgetTest do
  use Relay.DataCase, async: false

  alias Relay.Delivery.RetryBudget
  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture

  @v1 %{"window_ms" => 60_000, "max_ratio_bp" => 1000, "min_retries" => nil}
  @v2 %{@v1 | "min_retries" => 10}

  describe "T-27 decision" do
    test "T-27: with 100 attempts and 10 retries in the window the 11th retry is denied" do
      assert RetryBudget.decide(9, 100, @v1) == :allow
      assert RetryBudget.decide(10, 100, @v1) == :deny
      assert RetryBudget.decide(10, 100, @v2) == :deny
    end

    test "T-27, T-91: the minimum floor allows retries when traffic is low" do
      assert RetryBudget.decide(0, 0, @v1) == :deny
      assert RetryBudget.decide(5, 5, @v1) == :deny
      assert RetryBudget.decide(9, 9, @v2) == :allow
      assert RetryBudget.decide(10, 10, @v2) == :deny
    end

    test "T-27: the counters are per channel and provider account" do
      account = Relay.Id.generate()

      assert RetryBudget.keys(:sms, nil) == %{
               total: "retry_budget.total:sms:none",
               retry: "retry_budget.retry:sms:none"
             }

      assert RetryBudget.keys("push", account).total ==
               "retry_budget.total:push:" <> Relay.Id.to_string(account)
    end
  end

  describe "T-27 counters" do
    setup do
      TenantFixture.as_role("relay_worker")
      %{scope: TenantFixture.tenant!().live, parameters: DeliveryFixture.parameters(2)}
    end

    test "T-27: a retry storm is cut at ten percent of the window's attempts", ctx do
      account = Relay.Id.generate()

      for _ <- 1..90,
          do:
            {:ok, :ok} = Relay.Delivery.count_attempt(ctx.scope, ctx.parameters, :sms, account, 1)

      for _ <- 1..10,
          do:
            {:ok, :ok} = Relay.Delivery.count_attempt(ctx.scope, ctx.parameters, :sms, account, 2)

      assert {:ok, :deny} = Relay.Delivery.retry_budget(ctx.scope, ctx.parameters, :sms, account)
      assert {:ok, :allow} = Relay.Delivery.retry_budget(ctx.scope, ctx.parameters, :sms, nil)
    end
  end
end
