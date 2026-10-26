defmodule Relay.Channels.BreakerTest do
  use ExUnit.Case, async: true

  alias Relay.Channels
  alias Relay.Channels.Breaker
  alias Relay.Channels.Breaker.Core
  alias RelayTest.DeliveryFixture

  @row %{
    "window_ms" => 30_000,
    "min_throughput" => 20,
    "failure_ratio_bp" => 5000,
    "open_ms" => 30_000,
    "open_jitter_bp" => 3000,
    "half_open_probes" => 3,
    "half_open_successes" => 3,
    "p99_latency_ms" => nil
  }
  @jitter {"relay@node-a", "provider:test"}

  defp feed(core, now, calls, weight, slow? \\ false) do
    Enum.reduce(1..calls, core, &Core.record(&2, now + &1, @row, :allow, weight, slow?, @jitter))
  end

  defp target(provider, fields \\ []) do
    Map.merge(
      %{tenant_id: Relay.Id.generate(), environment: :live, channel: "slack", provider: provider},
      Map.new(fields)
    )
  end

  defp provider, do: "p" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  describe "T-25 state table" do
    test "T-25 (3): a closed breaker opens at the weighted ratio once the minimum volume is reached" do
      core = Core.new() |> feed(0, 9, 0) |> feed(100, 10, 1000)
      assert core.state == :closed
      core = feed(core, 200, 1, 1000)
      assert %Core{state: :open, open_count: 1} = core
    end

    test "T-25 (3): below the minimum volume no ratio is computed" do
      assert %Core{state: :closed} = Core.new() |> feed(0, 19, 1000)
    end

    test "T-25 (3): weights open fast for heavy and slowly for light failures" do
      assert %Core{state: :open} = Core.new() |> feed(0, 16, 0) |> feed(100, 4, 5000)
      assert %Core{state: :closed} = Core.new() |> feed(0, 10, 0) |> feed(100, 10, 500)
    end

    test "T-25 (4), CH-15: a 4xx application rejection counts as a call and never opens" do
      assert %Core{state: :closed} = Core.new() |> feed(0, 10_000, 0)
    end

    test "T-25 (5): the latency signal opens only when a threshold is set" do
      slow = Map.put(@row, "p99_latency_ms", 2000)
      assert Core.trip?(20, 0, 1, slow)
      refute Core.trip?(200, 0, 2, slow)
      refute Core.trip?(20, 0, 20, @row)
      assert Core.slow?(slow, 2001)
      refute Core.slow?(@row, 1_000_000)
    end

    test "T-25 (2), T-11: open rejects until open_until on the monotonic clock, then admits probes" do
      core = Core.new() |> feed(0, 20, 1000)
      until = core.open_until
      assert {{:reject, wait}, ^core} = Core.admit(core, until - 10, @row)
      assert wait == 10

      {:probe, core} = Core.admit(core, until, @row)
      assert core.state == :half_open
      {:probe, core} = Core.admit(core, until, @row)
      {:probe, core} = Core.admit(core, until, @row)
      assert {{:reject, 3000}, ^core} = Core.admit(core, until, @row)
    end

    test "T-25 (2): consecutive probe successes close and clear the window; one failure reopens" do
      open = Core.new() |> feed(0, 20, 1000)
      {:probe, half} = Core.admit(open, open.open_until, @row)

      closed =
        Enum.reduce(1..3, half, fn _, core ->
          {_, core} = Core.admit(core, open.open_until, @row)
          Core.record(core, open.open_until, @row, :probe, 0, false, @jitter)
        end)

      assert closed == Core.new()

      reopened = Core.record(half, open.open_until, @row, :probe, 1000, false, @jitter)
      assert %Core{state: :open, open_count: 2} = reopened
      assert reopened.open_until > open.open_until
    end

    test "T-25 (2): a probe failure of weight zero counts as a success" do
      open = Core.new() |> feed(0, 20, 1000)
      {:probe, half} = Core.admit(open, open.open_until, @row)

      assert %Core{state: :half_open, successes: 1} =
               Core.record(half, open.open_until, @row, :probe, 0, false, @jitter)
    end

    test "T-25 (3): counts older than the window drop out" do
      core = Core.new() |> feed(0, 15, 1000)
      core = feed(core, 31_000, 5, 1000)
      assert core.state == :closed
    end
  end

  describe "T-25 node breaker" do
    setup do: %{p: DeliveryFixture.parameters(1)}

    test "T-25 (9), T-11: the node breaker follows the table on injected monotonic time", %{p: p} do
      name = provider()
      t = target(name)
      now = 1_000_000

      for i <- 1..20 do
        {:allow, ticket} = Channels.check_breaker(p, t, now + i)
        :ok = Channels.record_breaker(ticket, {:failure, :transient, :server_error}, nil, now + i)
      end

      assert Breaker.provider_state(name) == :open

      assert {{:reject, :breaker_open, wait, rule}, _} = Channels.check_breaker(p, t, now + 100)
      assert rule == "breaker.provider." <> name
      assert wait > 30_000 - 100 and wait <= 39_000

      assert {:probe, ticket} = Channels.check_breaker(p, t, now + 100 + wait)
      assert Breaker.provider_state(name) == :half_open
      :ok = Channels.record_breaker(ticket, :success, nil, now + 100 + wait)
    end

    test "T-25 (4), CH-15: 4xx rejections never open the provider breaker", %{p: p} do
      name = provider()
      t = target(name)

      for i <- 1..1000 do
        {:allow, ticket} = Channels.check_breaker(p, t, i)
        :ok = Channels.record_breaker(ticket, {:failure, :permanent_target, nil}, nil, i)
      end

      assert Breaker.provider_state(name) == :closed
    end

    test "T-25 (1): sender_config opens the tenant breaker, not the provider breaker", %{p: p} do
      name = provider()
      t = target(name)

      for i <- 1..20 do
        {:allow, ticket} = Channels.check_breaker(p, t, i)
        :ok = Channels.record_breaker(ticket, {:failure, :sender_config, nil}, nil, i)
      end

      assert Breaker.tenant_state(t) == :open
      assert Breaker.provider_state(name) == :closed

      assert {{:reject, :breaker_open, _, "breaker.tenant_provider"}, _} =
               Channels.check_breaker(p, t, 100)
    end

    test "T-25 (9): an idle tenant breaker is swept after 15 minutes", %{p: p} do
      t = target(provider())
      {:allow, _ticket} = Channels.check_breaker(p, t, -5_000_000)
      assert Breaker.tenant_state(t) == :closed
      assert Breaker.sweep(-5_000_000 + 15 * 60_000) >= 1
      assert Breaker.tenant_state(t) == nil
    end
  end
end
