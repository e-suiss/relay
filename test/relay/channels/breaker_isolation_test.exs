defmodule Relay.Channels.BreakerIsolationTest do
  use ExUnit.Case, async: true

  alias Relay.Channels
  alias Relay.Channels.Breaker
  alias RelayTest.DeliveryFixture

  setup do
    provider = "p" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    target = fn ->
      %{tenant_id: Relay.Id.generate(), environment: :live, channel: "slack", provider: provider}
    end

    %{p: DeliveryFixture.parameters(1), provider: provider, a: target.(), b: target.()}
  end

  test "INV-40, T-25 (1): tenant A's authentication storm does not stop tenant B",
       %{p: p} = ctx do
    for i <- 1..500 do
      case Channels.check_breaker(p, ctx.a, i) do
        {:allow, ticket} -> Channels.record_breaker(ticket, {:failure, :auth, nil}, nil, i)
        {{:reject, :breaker_open, _, "breaker.tenant_provider"}, _} -> :ok
      end
    end

    assert Breaker.tenant_state(ctx.a) == :open
    assert Breaker.provider_state(ctx.provider) == :closed
    assert {:allow, ticket} = Channels.check_breaker(p, ctx.b, 600)
    :ok = Channels.record_breaker(ticket, :success, nil, 600)
    assert Breaker.tenant_state(ctx.b) == :closed
  end

  test "INV-40: the provider breaker does not open a tenant breaker", %{p: p} = ctx do
    for i <- 1..20 do
      {:allow, ticket} = Channels.check_breaker(p, ctx.a, i)
      Channels.record_breaker(ticket, {:failure, :transient, :timeout}, nil, i)
    end

    assert Breaker.provider_state(ctx.provider) == :open
    assert Breaker.tenant_state(ctx.a) == :closed

    assert {{:reject, :breaker_open, _, "breaker.provider." <> _}, _} =
             Channels.check_breaker(p, ctx.b, 30)
  end

  @tag timeout: 120_000
  test "CH-15, T-25 (4): a million permanent_target results do not open the breaker",
       %{p: p} = ctx do
    for i <- 1..1_000_000 do
      {:allow, ticket} = Channels.check_breaker(p, ctx.a, i)
      Channels.record_breaker(ticket, {:failure, :permanent_target, nil}, nil, i)
    end

    assert Breaker.provider_state(ctx.provider) == :closed
    assert Breaker.tenant_state(ctx.a) == :closed
  end
end
