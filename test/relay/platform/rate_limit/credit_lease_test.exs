defmodule Relay.Platform.RateLimit.CreditLeaseTest do
  use ExUnit.Case, async: true

  import Mox

  alias Relay.Platform.RateLimit
  alias Relay.Platform.RateLimit.CreditLease
  alias Relay.Platform.RateLimit.Gcra
  alias Relay.Platform.RateLimit.Limit
  alias Relay.ValkeyMock

  setup :verify_on_exit!

  defmodule SimClock do
    @moduledoc false
    def monotonic_ms, do: Process.get(:sim_ms, 0)
  end

  describe "T-20 (5) T-91 (1) credit leasing" do
    test "T-20 (5): SMS never leases; push, web push and email lease max(1, floor(B / 10))" do
      assert CreditLease.default("sms", 100) == {false, nil}
      assert CreditLease.default("whatsapp", 100) == {false, nil}
      assert CreditLease.default("push", 100) == {true, 10}
      assert CreditLease.default("web_push", 5) == {true, 1}
      assert CreditLease.default("email", 39) == {true, 3}

      assert CreditLease.block_size(CreditLease.default("sms", 100), 100) == nil
      assert CreditLease.block_size({true, nil}, 100) == 10
      assert CreditLease.block_size({true, 20}, 10) == nil
    end

    test "T-20 (5): an SMS limit decides every request centrally" do
      sms =
        Limit.new!(
          id: "provider.sms.mps",
          algorithm: :gcra,
          unit: :segment,
          limit: 100,
          period_ms: 1_000,
          burst: 100
        )

      expect(ValkeyMock, :command, 3, fn ["EVALSHA", _, "1", _key, _t, _b, "1" | _] ->
        {:ok, [0, 0, 0, 0, 1]}
      end)

      scope = Relay.Scope.new!(Relay.Id.generate(), :live)

      for _ <- 1..3 do
        assert {:allow, %{backend: :valkey}} =
                 RateLimit.check(scope, sms, ["sms", "acct"], 1, :l1,
                   lease: CreditLease.default("sms", 100),
                   backend: __MODULE__.Unstarted,
                   adapter: ValkeyMock
                 )
      end
    end

    test "T-20 (5): across N nodes the overrun stays within (N - 1) * k" do
      nodes = 4

      p = %{
        emission_us: Gcra.emission_us(100, 1_000),
        burst: 100,
        cost: 1,
        cap: -1,
        limit: 100,
        period_us: 1_000_000,
        offset_us: 0
      }

      k = CreditLease.block_size({true, nil}, p.burst)
      tables = for _ <- 1..nodes, do: :ets.new(:lease_node, [:set, :public])
      Process.put(:central, nil)
      duration_ms = 3_000

      allowed =
        for ms <- 0..(duration_ms - 1), node <- 0..(nodes - 1), reduce: 0 do
          acc ->
            Process.put(:sim_ms, ms)

            central = fn cost ->
              {code, _, next} = Gcra.step(Process.get(:central), %{p | cost: cost}, ms * 1000)
              if code == :allowed, do: Process.put(:central, next)
              code == :allowed
            end

            lease = fn ->
              if central.(k), do: {:allow, Gcra.ceil_div(k * p.emission_us, 1000)}, else: :deny
            end

            case CreditLease.spend({:t, :live, "push.mps:a", :l2}, 1, k, lease,
                   table: Enum.at(tables, node),
                   clock: SimClock
                 ) do
              :allowed -> acc + 1
              :central -> if central.(1), do: acc + 1, else: acc
            end
        end

      capacity = p.burst + div(duration_ms * 1000, p.emission_us)
      assert allowed <= capacity + (nodes - 1) * k
      assert allowed >= capacity - nodes * k
    end

    test "T-20 (5): a block expires after block_size * T and unspent credit is dropped" do
      table = :ets.new(:lease_expiry, [:set, :public])
      Process.put(:sim_ms, 0)
      lease = fn -> {:allow, 100} end
      opts = [table: table, clock: SimClock]
      assert CreditLease.spend(:key, 1, 10, lease, opts) == :allowed
      assert CreditLease.spend(:key, 9, 10, lease, opts) == :allowed
      assert CreditLease.spend(:key, 1, 10, fn -> :deny end, opts) == :central

      assert CreditLease.spend(:other, 1, 10, lease, opts) == :allowed
      Process.put(:sim_ms, 100)
      assert CreditLease.spend(:other, 1, 10, fn -> :deny end, opts) == :central
      assert CreditLease.spend(:key, 11, 10, lease, opts) == :central
    end
  end
end
