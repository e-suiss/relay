defmodule Relay.TenantWorkerTest do
  use ExUnit.Case, async: false

  alias Relay.TenantWorker

  defmodule Idle do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    @impl GenServer
    def init(opts), do: {:ok, opts[:idle_ms], opts[:idle_ms]}

    @impl GenServer
    def handle_info(:timeout, idle_ms), do: {:stop, :normal, idle_ms}
  end

  defp ensure(tenant, key, idle_ms \\ 60_000),
    do: TenantWorker.ensure(tenant, key, {Idle, idle_ms: idle_ms})

  describe "T-45 lazy tenant processes" do
    test "T-45: a worker starts on first use and is shared by later calls" do
      tenant = Relay.Id.generate()
      assert TenantWorker.whereis(tenant, :apns) == nil

      {:ok, pid} = ensure(tenant, :apns)
      assert {:ok, ^pid} = ensure(tenant, :apns)
      assert TenantWorker.whereis(tenant, :apns) == pid

      {:ok, other} = ensure(Relay.Id.generate(), :apns)
      assert other != pid
      {:ok, breaker} = ensure(tenant, :breaker)
      assert breaker != pid
    end

    test "T-45: an idle worker stops itself and the next use starts a new one" do
      tenant = Relay.Id.generate()
      {:ok, pid} = ensure(tenant, :apns, 20)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      assert eventually(fn -> TenantWorker.whereis(tenant, :apns) == nil end)

      {:ok, again} = ensure(tenant, :apns, 20)
      assert again != pid
    end

    test "T-45: a stopped worker is not restarted by the supervisor" do
      tenant = Relay.Id.generate()
      {:ok, pid} = ensure(tenant, :apns)
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
      assert eventually(fn -> TenantWorker.whereis(tenant, :apns) == nil end)
    end

    test "T-45: every worker states an idle timeout" do
      assert_raise KeyError, fn -> TenantWorker.ensure(Relay.Id.generate(), :apns, {Idle, []}) end

      assert_raise ArgumentError, fn ->
        TenantWorker.ensure(Relay.Id.generate(), :apns, {Idle, idle_ms: 0})
      end
    end
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end
end
