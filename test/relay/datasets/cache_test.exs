defmodule Relay.Datasets.CacheTest do
  use ExUnit.Case, async: false

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
end
