defmodule Relay.Platform.ValkeyLossTest do
  use Relay.DataCase, async: false

  alias Relay.Platform.Backend
  alias Relay.Platform.Concurrency
  alias Relay.Platform.RateLimit
  alias Relay.Platform.RateLimit.Limit
  alias Relay.Platform.RateLimit.Scripts
  alias Relay.Platform.Signal
  alias Relay.Platform.Signal.Hub
  alias Relay.Platform.Valkey
  alias Relay.Repo
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

  @limit Limit.new!(
           id: "test.loss",
           algorithm: :gcra,
           unit: :message,
           limit: 1,
           period_ms: 3_600_000,
           burst: 1
         )

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

  defp eventually(fun, n \\ 100) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && eventually(fun, n - 1)
    end
  end

  describe "OP-29 L-55 losing Valkey loses no record" do
    setup do
      await_valkey(100)
      %{tenant: TenantFixture.tenant!()}
    end

    test "OP-29: wiping the limiter keys costs only a fresh window; decisions continue and no record is lost",
         %{tenant: tenant} do
      scope = tenant.test
      opts = [backend: __MODULE__.Unstarted]
      tenants_before = Repo.query!("SELECT count(*) FROM relay.tenants").rows

      assert {:allow, %{backend: :valkey}} =
               RateLimit.check(scope, @limit, ["sms", "a"], 1, :l1, opts)

      assert {:deny, _, _} = RateLimit.check(scope, @limit, ["sms", "a"], 1, :l1, opts)

      {:ok, key} = Limit.key(@limit, ["sms", "a"])
      {:ok, vkey} = Scripts.key(scope, ["rl", "g"], key)
      assert {:ok, 1} = Valkey.adapter().command(["DEL", vkey.name])

      assert {:allow, _} = RateLimit.check(scope, @limit, ["sms", "a"], 1, :l1, opts)
      assert {:deny, _, _} = RateLimit.check(scope, @limit, ["sms", "a"], 1, :l1, opts)
      assert Repo.query!("SELECT count(*) FROM relay.tenants").rows == tenants_before
    end

    test "T-9 (3): when Valkey is unreachable limits and concurrency move to PostgreSQL and still hold",
         %{tenant: tenant} do
      scope = tenant.test
      name = __MODULE__.LossBackend

      start_supervised!(
        {Backend, name: name, adapter: DownValkey, hold_ms: 60_000, ping_ms: 60_000}
      )

      opts = [backend: name, adapter: DownValkey]

      assert {:allow, %{backend: :pg}} =
               RateLimit.check(scope, @limit, ["sms", "b"], 1, :l1, opts)

      assert {:deny, _, "rate_limit.test.loss"} =
               RateLimit.check(scope, @limit, ["sms", "b"], 1, :l1, opts)

      assert {:ok, 1} = Concurrency.acquire(scope, "cc.tenant_deliveries", 1, "oban:1", opts)
      assert {:full, _} = Concurrency.acquire(scope, "cc.tenant_deliveries", 1, "oban:2", opts)
      assert :ok = Concurrency.release(scope, "cc.tenant_deliveries", "oban:1", opts)
      assert {:ok, 1} = Concurrency.acquire(scope, "cc.tenant_deliveries", 1, "oban:2", opts)
    end

    test "T-9: on return the slots are asked from both backends while the lease horizon lasts", %{
      tenant: tenant
    } do
      scope = tenant.test
      name = __MODULE__.DualBackend

      start_supervised!(
        {Backend, name: name, adapter: Valkey.adapter(), hold_ms: 60_000, ping_ms: 60_000}
      )

      Backend.report_failure(name)
      eventually(fn -> Backend.state(name).phase == :pg end)
      send(name, :ping)
      eventually(fn -> Backend.current_mode(Concurrency.lease_ms(), name) == :dual end)
      opts = [backend: name]

      assert {:ok, 1} = Concurrency.acquire(scope, "cc.tenant_deliveries", 1, "oban:d1", opts)
      assert {:full, _} = Concurrency.acquire(scope, "cc.tenant_deliveries", 1, "oban:d2", opts)

      assert {:ok, 1} =
               Concurrency.acquire(scope, "cc.tenant_deliveries", 1, "oban:d1",
                 backend: __MODULE__.Unstarted
               )

      assert {:ok, {:renewed, 1, 0}} =
               Concurrency.Store.acquire(scope, "cc.tenant_deliveries", 1, "oban:d1", 120_000)
    end
  end

  describe "T-10 signals fall back to polling" do
    setup do
      await_valkey(100)
      {:ok, topic} = Signal.topic("tnt_#{System.unique_integer([:positive])}", "test", ["loss"])
      :ok = Signal.subscribe(topic)
      on_exit(fn -> Signal.unsubscribe(topic, Hub) end)
      eventually(fn -> Hub.topics(Hub)[topic] == :up end)
      %{topic: topic}
    end

    test "OP-29: after the pub/sub connection is lost a subscriber is told to poll the database",
         %{topic: topic} do
      {:ok, killed} = Valkey.adapter().command(["CLIENT", "KILL", "TYPE", "pubsub"])
      assert killed >= 1
      assert_receive {:relay_signal, ^topic, :poll}, 3_000
    end
  end
end
