defmodule Relay.Tenancy.KillSwitchPropagationTest do
  use Relay.SqlCase, async: false

  alias Relay.Platform.Signal.Hub
  alias Relay.Tenancy.KillSwitch
  alias Relay.Tenancy.KillSwitch.Cache
  alias Relay.Tenancy.KillSwitch.Snapshot

  @operator %{kind: :installation_operator, ref: "ops@example"}

  defp eventually(fun, deadline_ms) do
    started = System.monotonic_time(:millisecond)
    wait(fun, started + deadline_ms)
    System.monotonic_time(:millisecond) - started
  end

  defp wait(fun, until) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > until -> flunk("condition not reached in time")
      true -> Process.sleep(20) && wait(fun, until)
    end
  end

  defp start(opts) do
    name = make_ref()
    pid = start_supervised!({Cache, Keyword.put(opts, :name, name)}, id: name)
    on_exit(fn -> Cache.forget(name) end)
    eventually(fn -> Cache.current(name) != :unknown end, 5_000)
    {name, pid}
  end

  defp engage! do
    later = DateTime.add(DateTime.utc_now(), 3600, :second)

    {:ok, %{result: :engaged, id: external}} =
      KillSwitch.engage(
        %{scope_kind: :platform, reason: "propagation", expires_at: later, channel: "voice"},
        @operator
      )

    {:ok, id} = Relay.ExternalId.decode(external, ["ksw"])
    id
  end

  defp holds?(name, id) do
    case Cache.current(name) do
      %Snapshot{index: index} -> Enum.any?(Map.get(index, :platform, []), &(&1.id == id))
      :unknown -> false
    end
  end

  test "TN-39: a write reaches a node over the Valkey signal within two seconds" do
    {name, _pid} = start(refresh_ms: 600_000)
    eventually(fn -> Hub.topics(Hub)[Cache.topic()] == :up end, 5_000)

    id = engage!()
    elapsed = eventually(fn -> holds?(name, id) end, 2_000)
    assert elapsed <= 2_000
  end

  test "TN-39: without the signal the node still picks the write up by polling" do
    {name, _pid} = start(subscribe: fn _topic -> :ok end, refresh_ms: 200)
    id = engage!()
    eventually(fn -> holds?(name, id) end, 2_000)
  end

  test "TN-39: a re-read tick of the signal hub reloads the state" do
    {name, pid} = start(subscribe: fn _topic -> :ok end, refresh_ms: 600_000)
    id = engage!()
    refute holds?(name, id)
    send(pid, {:relay_signal, Cache.topic(), :poll})
    eventually(fn -> holds?(name, id) end, 2_000)
  end
end
