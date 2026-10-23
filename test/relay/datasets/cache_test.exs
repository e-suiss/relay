defmodule Relay.Datasets.CacheTest do
  use ExUnit.Case, async: false

  import Mox

  alias Relay.Datasets.Cache

  setup do
    name = __MODULE__.Cache
    test = self()
    start_supervised!({Cache, name: name, subscribe: &send(test, {:subscribed, &1})})
    %{cache: name, pid: Process.whereis(name)}
  end

  defp counting_load(value) do
    test = self()

    fn ->
      send(test, :loaded)
      {:ok, value}
    end
  end

  describe "OP-65 (6) CH-18 active versions are cached until a signal" do
    test "OP-65: a cached version is served without reading again", %{cache: cache} do
      assert Cache.fetch(cache, :k, "topic:a", counting_load(1)) == {:ok, 1}
      assert_received {:subscribed, "topic:a"}
      assert_received :loaded
      assert Cache.fetch(cache, :k, "topic:a", counting_load(2)) == {:ok, 1}
      refute_received :loaded
    end

    test "CH-18: an activation signal drops the entry, so the next read sees the new version",
         %{cache: cache, pid: pid} do
      {:ok, 1} = Cache.fetch(cache, :k, "topic:a", counting_load(1))
      send(pid, {:relay_signal, "topic:a", {:seq, 7}})
      :sys.get_state(pid)
      assert Cache.fetch(cache, :k, "topic:a", counting_load(2)) == {:ok, 2}
    end

    test "OP-65: a re-read tick, as while Valkey is unavailable, drops the entry too", %{
      cache: cache,
      pid: pid
    } do
      {:ok, 1} = Cache.fetch(cache, :k, "topic:a", counting_load(1))
      send(pid, {:relay_signal, "topic:a", :poll})
      :sys.get_state(pid)
      assert Cache.fetch(cache, :k, "topic:a", counting_load(3)) == {:ok, 3}
    end

    test "OP-65: a signal that arrives during the read keeps the stale result out of the cache",
         %{cache: cache, pid: pid} do
      stale = fn ->
        send(pid, {:relay_signal, "topic:a", {:seq, 1}})
        :sys.get_state(pid)
        {:ok, :stale}
      end

      assert Cache.fetch(cache, :k, "topic:a", stale) == {:ok, :stale}
      assert Cache.fetch(cache, :k, "topic:a", counting_load(:fresh)) == {:ok, :fresh}
      assert_received :loaded
    end

    test "OP-65: errors and uncached reads are not stored; one subscription per topic", %{
      cache: cache
    } do
      assert Cache.fetch(cache, :k, "topic:a", fn -> {:error, :down} end) == {:error, :down}
      assert Cache.fetch(cache, :k, "topic:a", counting_load(1), cache: false) == {:ok, 1}
      assert Cache.fetch(cache, :k, "topic:a", counting_load(2)) == {:ok, 2}
      assert Cache.fetch(cache, :other, "topic:a", counting_load(3)) == {:ok, 3}
      assert_received {:subscribed, "topic:a"}
      refute_received {:subscribed, _}
    end

    test "OP-65: a signal drops only the entries of its own topic", %{cache: cache, pid: pid} do
      {:ok, 1} = Cache.fetch(cache, :a, "topic:a", counting_load(1))
      {:ok, 1} = Cache.fetch(cache, :b, "topic:b", counting_load(1))
      send(pid, {:relay_signal, "topic:a", {:seq, 2}})
      :ok = Cache.invalidate(cache, :none)
      assert Cache.fetch(cache, :a, "topic:a", counting_load(2)) == {:ok, 2}
      assert Cache.fetch(cache, :b, "topic:b", counting_load(2)) == {:ok, 1}
    end
  end

  describe "OP-71 (8) cached data set versions have a ten-minute age limit" do
    setup %{pid: pid} do
      previous = Application.fetch_env!(:relay, :clock)
      Application.put_env(:relay, :clock, Relay.ClockMock)
      on_exit(fn -> Application.put_env(:relay, :clock, previous) end)

      now = :counters.new(1, [])
      stub(Relay.ClockMock, :monotonic_ms, fn -> :counters.get(now, 1) end)
      allow(Relay.ClockMock, self(), pid)
      %{now: now}
    end

    test "OP-71: a fresh cached data set version is served from the cache", %{
      cache: cache,
      now: now
    } do
      assert Cache.fetch(cache, :k, "topic:a", counting_load(1)) == {:ok, 1}
      assert_received :loaded
      :counters.put(now, 1, 599_999)
      assert Cache.fetch(cache, :k, "topic:a", counting_load(2)) == {:ok, 1}
      refute_received :loaded
    end

    test "OP-71: a cached data set version is re-read after ten minutes", %{
      cache: cache,
      now: now
    } do
      assert Cache.fetch(cache, :k, "topic:a", counting_load(1)) == {:ok, 1}
      assert_received :loaded
      :counters.put(now, 1, 600_000)
      assert Cache.fetch(cache, :k, "topic:a", counting_load(2)) == {:ok, 2}
      assert_received :loaded
      assert Cache.fetch(cache, :k, "topic:a", counting_load(3)) == {:ok, 2}
      refute_received :loaded
      assert_received {:subscribed, "topic:a"}
      refute_received {:subscribed, _}
    end

    test "OP-71: the age limit is configurable", %{now: now} do
      test = self()

      pid =
        start_supervised!({Cache, name: nil, max_age_ms: 1_000, subscribe: &send(test, &1)},
          id: :short
        )

      allow(Relay.ClockMock, self(), pid)
      {:ok, 1} = Cache.fetch(pid, :k, "topic:a", counting_load(1))
      :counters.put(now, 1, 1_000)
      assert Cache.fetch(pid, :k, "topic:a", counting_load(2)) == {:ok, 2}
    end
  end
end
