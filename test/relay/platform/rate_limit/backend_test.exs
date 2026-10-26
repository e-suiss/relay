defmodule Relay.Platform.RateLimit.BackendTest do
  use Relay.DataCase, async: false

  alias Relay.Platform.Backend
  alias Relay.Platform.RateLimit
  alias Relay.Platform.RateLimit.Limit
  alias Relay.Platform.RateLimit.Scripts
  alias Relay.Platform.RateLimit.Store
  alias Relay.Platform.Valkey
  alias RelayTest.TenantFixture

  defmodule DownValkey do
    @moduledoc false
    @behaviour Relay.Platform.Valkey
    @impl true
    def command(_command), do: {:error, %Redix.ConnectionError{reason: :closed}}
    @impl true
    def pipeline(_commands), do: {:error, %Redix.ConnectionError{reason: :closed}}
    @impl true
    def subscribe(_channel), do: {:error, %Redix.ConnectionError{reason: :closed}}
    @impl true
    def unsubscribe(_channel), do: :ok
  end

  @g1 Limit.new!(
        id: "test.g1",
        algorithm: :gcra,
        unit: :message,
        limit: 10,
        period_ms: 1_000,
        burst: 1
      )
  @hourly Limit.new!(
            id: "test.hourly",
            algorithm: :gcra,
            unit: :message,
            limit: 1,
            period_ms: 3_600_000,
            burst: 1
          )

  defp backend(adapter) do
    name = __MODULE__.Backend
    start_supervised!({Backend, name: name, adapter: adapter, hold_ms: 60_000, ping_ms: 60_000})
    name
  end

  defp eventually(fun, n \\ 100) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("condition not reached")
      true -> Process.sleep(10) && eventually(fun, n - 1)
    end
  end

  defp await_valkey(0), do: flunk("Valkey is not reachable")

  defp await_valkey(n) do
    if Valkey.ping() == :ok,
      do: :ok,
      else:
        (
          Process.sleep(50)
          await_valkey(n - 1)
        )
  end

  describe "INV-44 T-9 (3) Valkey loss falls back to PostgreSQL" do
    test "INV-44: G11 with Valkey unreachable the same request is decided by PostgreSQL, which still limits" do
      scope = TenantFixture.tenant!().test
      server = backend(DownValkey)
      opts = [backend: server, adapter: DownValkey]

      assert {:allow, %{backend: :pg}} =
               RateLimit.check(scope, @g1, ["sms", "acct"], 1, :l1, opts)

      eventually(fn -> Backend.state(server).phase == :pg end)

      assert {:deny, retry, "rate_limit.test.g1"} =
               RateLimit.check(scope, @g1, ["sms", "acct"], 1, :l1, opts)

      assert retry in 1..100
    end

    test "T-20: a cost above the burst is denied under its own rule" do
      scope = TenantFixture.tenant!().test
      server = backend(DownValkey)
      opts = [backend: server, adapter: DownValkey]

      assert {:deny, 1_000, "rate_limit.cost_exceeds_burst"} =
               RateLimit.check(scope, @g1, ["sms", "big"], 2, :l1, opts)
    end

    test "INV-44: with neither backend answering the decision is a denial for one second, never unlimited" do
      scope = Relay.Scope.new!(Relay.Id.generate(), :test)
      server = backend(DownValkey)
      opts = [backend: server, adapter: DownValkey]

      for _ <- 1..3 do
        assert {:deny, 1_000, "rate_limit.backend_unavailable"} =
                 RateLimit.check(scope, @g1, ["sms", "acct"], 1, :l1, opts)
      end

      assert {:error, %Relay.Error{code: :limiter_unavailable}} =
               RateLimit.counter(scope, "rb.test:sms:none", 60_000, :incr, 1, opts)
    end

    test "CH-17: a counter that cannot be read in Valkey is read from the fallback" do
      scope = TenantFixture.tenant!().test
      server = backend(DownValkey)
      opts = [backend: server, adapter: DownValkey]

      assert {:ok, 1} = RateLimit.counter(scope, "rbx:sms:none", 60_000, :incr, 1, opts)
      assert {:ok, 2} = RateLimit.counter(scope, "rbx:sms:none", 60_000, :incr, 1, opts)
      assert {:ok, {1, 0}} = RateLimit.ring(scope, "dms:tenant:tenant", 1, 5, 60, opts)
    end
  end

  describe "T-9 (5) dual after Valkey returns" do
    setup do
      await_valkey(100)
    end

    test "T-9: G12 in dual both backends decide and the stricter one wins" do
      scope = TenantFixture.tenant!().test
      server = backend(Valkey.adapter())
      {:ok, key} = Limit.key(@hourly, ["sms", "acct"])

      p = %{
        emission_us: 3_600_000_000,
        burst: 1,
        cost: 1,
        cap: -1,
        limit: 1,
        period_us: 3_600_000_000,
        offset_us: 0
      }

      assert {:ok, {:allowed, 0}} = Store.gcra(scope, key, p)

      Backend.report_failure(server)
      eventually(fn -> Backend.state(server).phase == :pg end)
      send(server, :ping)
      eventually(fn -> Backend.current_mode(Limit.horizon_ms(@hourly), server) == :dual end)

      assert {:deny, _retry, "rate_limit.test.hourly"} =
               RateLimit.check(scope, @hourly, ["sms", "acct"], 1, :l1, backend: server)

      {:ok, vkey} = Scripts.key(scope, ["rl", "g"], key)
      assert {:ok, 1} = Valkey.adapter().command(["EXISTS", vkey.name])
    end

    test "T-9: with both backends empty in dual the first request passes and is counted on both" do
      scope = TenantFixture.tenant!().test
      server = backend(Valkey.adapter())
      Backend.report_failure(server)
      eventually(fn -> Backend.state(server).phase == :pg end)
      send(server, :ping)
      eventually(fn -> Backend.current_mode(Limit.horizon_ms(@hourly), server) == :dual end)

      assert {:allow, %{backend: :dual}} =
               RateLimit.check(scope, @hourly, ["sms", "b"], 1, :l1, backend: server)

      assert {:deny, _, _} =
               RateLimit.check(scope, @hourly, ["sms", "b"], 1, :l1, backend: server)

      {:ok, key} = Limit.key(@hourly, ["sms", "b"])

      p = %{
        emission_us: 3_600_000_000,
        burst: 1,
        cost: 1,
        cap: -1,
        limit: 1,
        period_us: 3_600_000_000,
        offset_us: 0
      }

      assert {:ok, {:limited, _}} = Store.gcra(scope, key, p)
    end
  end
end
