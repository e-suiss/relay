defmodule Relay.Channels.BreakerHalfOpenTest do
  use ExUnit.Case, async: true

  alias Relay.Channels
  alias Relay.Channels.Breaker
  alias RelayTest.DeliveryFixture

  setup do
    provider = "p" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    target = %{
      tenant_id: Relay.Id.generate(),
      environment: :live,
      channel: "slack",
      provider: provider
    }

    p = DeliveryFixture.parameters(1)

    for i <- 1..20 do
      {:allow, ticket} = Channels.check_breaker(p, target, i)
      Channels.record_breaker(ticket, {:failure, :transient, :server_error}, nil, i)
    end

    {{:reject, :breaker_open, wait, _}, _} = Channels.check_breaker(p, target, 20)
    %{p: p, provider: provider, target: target, at: 20 + wait}
  end

  test "T-25 (2): only three concurrent probes pass a half-open breaker", ctx do
    decisions =
      1..50
      |> Task.async_stream(fn _ -> Channels.check_breaker(ctx.p, ctx.target, ctx.at) end,
        max_concurrency: 50,
        ordered: false
      )
      |> Enum.map(fn {:ok, {decision, _ticket}} -> decision end)

    assert Enum.count(decisions, &(&1 == :probe)) == 3
    assert Enum.count(decisions, &match?({:reject, :breaker_open, _, _}, &1)) == 47
    assert Breaker.provider_state(ctx.provider) == :half_open
  end

  test "T-25 (2): three consecutive probe successes close the breaker and announce it", ctx do
    parent = self()
    handler = "half-open-test-" <> ctx.provider

    :telemetry.attach(
      handler,
      [:relay, :breaker, :transition],
      fn _, _, meta, _ ->
        if meta.provider == ctx.provider, do: send(parent, {:transition, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    tickets = for _ <- 1..3, do: elem(Channels.check_breaker(ctx.p, ctx.target, ctx.at), 1)
    assert_receive {:transition, %{level: :provider, from: :open, to: :half_open}}

    for ticket <- tickets, do: Channels.record_breaker(ticket, :success, nil, ctx.at)

    assert Breaker.provider_state(ctx.provider) == :closed
    assert_receive {:transition, %{level: :provider, from: :half_open, to: :closed}}
    assert {:allow, _} = Channels.check_breaker(ctx.p, ctx.target, ctx.at + 1)
  end

  test "T-25 (2): one probe failure opens the breaker again with a later end", ctx do
    {:probe, first} = Channels.check_breaker(ctx.p, ctx.target, ctx.at)
    {:probe, second} = Channels.check_breaker(ctx.p, ctx.target, ctx.at)
    Channels.record_breaker(first, :success, nil, ctx.at)
    Channels.record_breaker(second, {:failure, :transient, :timeout}, nil, ctx.at)

    assert Breaker.provider_state(ctx.provider) == :open

    assert {{:reject, :breaker_open, wait, _}, _} =
             Channels.check_breaker(ctx.p, ctx.target, ctx.at + 1)

    assert wait >= 30_000 - 1
  end
end
