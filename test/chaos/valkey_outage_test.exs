defmodule Relay.Chaos.ValkeyOutageTest do
  use Relay.DataCase, async: false

  @moduletag :nightly
  if is_nil(System.get_env("TOXIPROXY_URL")), do: @moduletag(skip: "needs TOXIPROXY_URL")

  alias Relay.Platform.Backend
  alias Relay.Platform.RateLimit
  alias Relay.Platform.RateLimit.Limit
  alias Relay.Platform.Signal
  alias Relay.Platform.Signal.Hub
  alias Relay.Platform.Valkey
  alias RelayTest.TenantFixture
  alias RelayTest.Toxiproxy

  @proxy "valkey"
  @limit Limit.new!(
           id: "test.chaos",
           algorithm: :gcra,
           unit: :message,
           limit: 1,
           period_ms: 3_600_000,
           burst: 1
         )

  defp eventually(fun, n \\ 250) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && eventually(fun, n - 1)
    end
  end

  setup do
    Toxiproxy.enabled(@proxy, true)
    on_exit(fn -> Toxiproxy.enabled(@proxy, true) end)
    eventually(fn -> Valkey.ping() == :ok end)
    {:ok, topic} = Signal.topic("tnt_#{System.unique_integer([:positive])}", "test", ["chaos"])
    :ok = Signal.subscribe(topic)
    on_exit(fn -> Signal.unsubscribe(topic, Hub) end)
    eventually(fn -> Hub.topics(Hub)[topic] == :up end)
    %{topic: topic, tenant: TenantFixture.tenant!()}
  end

  test "OP-93: a Valkey outage moves signals to polling and limits to PostgreSQL, then recovers",
       %{topic: topic, tenant: tenant} do
    name = __MODULE__.Backend
    start_supervised!({Backend, name: name, adapter: Valkey.adapter(), ping_ms: 500})
    opts = [backend: name]
    started = System.monotonic_time(:millisecond)

    Toxiproxy.enabled(@proxy, false)
    assert_receive {:relay_signal, ^topic, :poll}, 5_000
    polling_ms = System.monotonic_time(:millisecond) - started

    assert {:allow, %{backend: :pg}} =
             RateLimit.check(tenant.test, @limit, ["sms", "chaos"], 1, :l1, opts)

    assert {:deny, _retry, "rate_limit.limit:test.chaos"} =
             RateLimit.check(tenant.test, @limit, ["sms", "chaos"], 1, :l1, opts)

    Toxiproxy.enabled(@proxy, true)

    eventually(
      fn ->
        _ = Signal.publish(topic, 41)

        receive do
          {:relay_signal, ^topic, {:seq, 41}} -> true
        after
          100 -> false
        end
      end,
      600
    )

    IO.puts("valkey outage: polling after #{polling_ms} ms")
  end
end
