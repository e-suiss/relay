defmodule Relay.Tenancy.KillSwitchCacheTest do
  use ExUnit.Case, async: false

  alias Relay.Tenancy.KillSwitch
  alias Relay.Tenancy.KillSwitch.Cache
  alias Relay.Tenancy.KillSwitch.Record
  alias Relay.Tenancy.KillSwitch.Snapshot

  @topic "relay:s:signal:killswitch:test"

  defp record(attrs) do
    struct!(
      Record,
      Map.merge(
        %{
          id: Relay.Id.generate(),
          tenant_id: Relay.Id.generate(),
          environment: :live,
          scope_kind: :platform,
          target_kind: :all,
          state: :off,
          status: :active,
          expires_at: nil,
          created_at: DateTime.utc_now()
        },
        Map.new(attrs)
      )
    )
  end

  defp message(record) do
    %{
      tenant_id: Relay.Id.generate(),
      environment: :live,
      channel: "sms",
      message_class: "transactional",
      notification_id: Relay.Id.generate(),
      tenant_hint: record.id
    }
  end

  defp start(results, opts \\ []) do
    name = make_ref()
    {:ok, script} = Agent.start_link(fn -> results end)
    test = self()

    load = fn ->
      result =
        Agent.get_and_update(script, fn
          [last] -> {last, [last]}
          [next | rest] -> {next, rest}
        end)

      send(test, {:loaded, result})
      result
    end

    pid =
      start_supervised!(
        {Cache,
         Keyword.merge(
           [
             name: name,
             load: load,
             subscribe: fn _ -> :ok end,
             topic: @topic,
             refresh_ms: 60_000
           ],
           opts
         )},
        id: name
      )

    on_exit(fn -> Cache.forget(name) end)
    %{name: name, pid: pid, script: script}
  end

  defp error, do: {:error, Relay.Error.new(:kill_switch_unreadable, "down")}

  defp loaded(pid) do
    assert_receive {:loaded, result}, 2_000
    _ = :sys.get_state(pid)
    result
  end

  describe "INV-43 TN-38 fail-safe state" do
    test "INV-43: a node that could never read the state holds every message" do
      %{name: name, pid: pid} = start([error()])
      loaded(pid)
      assert Cache.current(name) == :unknown

      assert KillSwitch.evaluate(Cache.current(name), message(record([])), DateTime.utc_now()) ==
               {:hold, "killswitch.state_unknown"}
    end

    test "TN-38: a failed read keeps the last known state and an outage never releases a record" do
      off = record([])
      %{name: name, pid: pid} = start([{:ok, 3, [off]}, error()])
      loaded(pid)
      assert %Snapshot{generation: 3, count: 1} = Cache.current(name)

      send(pid, {:relay_signal, @topic, :poll})
      assert {:error, _} = loaded(pid)
      assert %Snapshot{generation: 3, count: 1} = snapshot = Cache.current(name)

      assert {:pause, id, "killswitch.off"} =
               KillSwitch.evaluate(snapshot, message(off), DateTime.utc_now())

      assert id == off.id
    end

    test "TN-38: a record whose TTL passes during an outage stops applying" do
      expires = DateTime.add(DateTime.utc_now(), 60, :second)
      off = record(expires_at: expires)
      %{name: name, pid: pid} = start([{:ok, 1, [off]}, error()])
      loaded(pid)
      send(pid, {:relay_signal, @topic, :poll})
      loaded(pid)

      snapshot = Cache.current(name)
      assert {:pause, _, _} = KillSwitch.evaluate(snapshot, message(off), DateTime.utc_now())
      assert :allow = KillSwitch.evaluate(snapshot, message(off), DateTime.add(expires, 1))
    end

    test "TN-38: no copy is kept across a restart; a new cache starts unknown" do
      %{name: name, pid: pid} = start([{:ok, 1, []}])
      loaded(pid)
      assert %Snapshot{} = Cache.current(name)
      Cache.forget(name)
      assert Cache.current(name) == :unknown
    end
  end

  describe "TN-39 reload" do
    test "TN-39: a result of a smaller generation than the held one is dropped" do
      %{name: name, pid: pid} = start([{:ok, 5, [record([])]}, {:ok, 4, []}])
      loaded(pid)
      send(pid, {:relay_signal, @topic, :poll})
      loaded(pid)
      assert %Snapshot{generation: 5, count: 1} = Cache.current(name)
    end

    test "TN-39: a signal of a newer generation reloads, an older one does not" do
      %{name: name, pid: pid} = start([{:ok, 2, []}, {:ok, 7, [record([])]}])
      loaded(pid)
      send(pid, {:relay_signal, @topic, {:seq, 2}})
      refute_receive {:loaded, _}, 200
      send(pid, {:relay_signal, @topic, {:seq, 7}})
      loaded(pid)
      assert %Snapshot{generation: 7, count: 1} = Cache.current(name)
    end

    test "TN-39: without any signal the state is re-read on the refresh interval" do
      %{name: name, pid: pid} = start([{:ok, 1, []}, {:ok, 2, [record([])]}], refresh_ms: 100)
      loaded(pid)
      loaded(pid)
      assert %Snapshot{generation: 2} = Cache.current(name)
    end

    test "TN-39: the snapshot is one immutable value indexed by scope" do
      tenant = Relay.Id.generate()
      platform = record([])
      own = record(scope_kind: :tenant, tenant_id: tenant)
      sub = record(scope_kind: :subtenant, tenant_id: tenant, scope_ref: "s")
      snapshot = Snapshot.new(1, [platform, own, sub, record(status: :released)])

      assert snapshot.count == 3

      assert Map.keys(snapshot.index) |> Enum.sort() ==
               Enum.sort([:platform, {:tenant, tenant, :live}, {:subtenant, tenant, :live, "s"}])

      assert Snapshot.candidates(snapshot, tenant, :live, subtenant: "s") |> length() == 3
      assert Snapshot.candidates(snapshot, tenant, :live, subtenant: nil) |> length() == 2
      assert Snapshot.candidates(snapshot, tenant, :test, []) == [platform]
    end
  end
end
