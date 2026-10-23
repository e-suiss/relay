defmodule Relay.Tenancy.KeyCacheTest do
  use ExUnit.Case, async: false

  import Mox

  alias Relay.Redacted
  alias Relay.Tenancy.KeyCache

  setup :verify_on_exit!

  @key :binary.copy(<<0x5A>>, 32)

  setup do
    previous = Application.fetch_env!(:relay, :clock)
    Application.put_env(:relay, :clock, Relay.ClockMock)
    on_exit(fn -> Application.put_env(:relay, :clock, previous) end)

    now = :counters.new(1, [])
    stub(Relay.ClockMock, :monotonic_ms, fn -> :counters.get(now, 1) end)
    cache = start_supervised!({KeyCache, name: nil, sweep_ms: 3_600_000})
    allow(Relay.ClockMock, self(), cache)
    %{cache: cache, now: now}
  end

  defp at(now, ms), do: :counters.put(now, 1, ms)

  describe "TN-66 data key cache" do
    test "TN-66: an unwrapped key is cached for ten minutes", %{cache: cache, now: now} do
      assert KeyCache.fetch(cache, :k) == :miss
      generation = KeyCache.generation(cache)
      assert KeyCache.put(cache, :k, Redacted.wrap(@key), generation) == :ok

      at(now, 599_999)
      assert {:ok, key} = KeyCache.fetch(cache, :k)
      assert Redacted.expose(key) == @key

      at(now, 600_000)
      assert KeyCache.fetch(cache, :k) == :miss
      assert KeyCache.size(cache) == 0
    end

    test "TN-66: a flush drops every key and refuses keys read before it", %{cache: cache} do
      before = KeyCache.generation(cache)
      :ok = KeyCache.put(cache, :a, Redacted.wrap(@key), before)
      :ok = KeyCache.put(cache, :b, Redacted.wrap(@key), before)

      assert KeyCache.flush(cache) == :ok
      assert KeyCache.size(cache) == 0
      assert KeyCache.put(cache, :a, Redacted.wrap(@key), before) == :stale
      assert KeyCache.fetch(cache, :a) == :miss
      assert KeyCache.put(cache, :a, Redacted.wrap(@key), KeyCache.generation(cache)) == :ok
    end

    test "TN-66: a cache that is not running is a miss and refuses keys" do
      cache = :relay_key_cache_not_running
      assert KeyCache.fetch(cache, :k) == :miss
      assert KeyCache.generation(cache) == nil
      assert KeyCache.put(cache, :k, Redacted.wrap(@key), 0) == :stale
      assert KeyCache.flush(cache) == :ok
    end

    test "T-46: the cache process is sensitive and its status shows only the number of keys", %{
      cache: cache
    } do
      :ok = KeyCache.put(cache, :k, Redacted.wrap(@key), KeyCache.generation(cache))

      status = :sys.get_status(cache)
      refute inspect(status, limit: :infinity, printable_limit: :infinity) =~ Base.encode16(@key)
      refute :erlang.term_to_binary(status) =~ @key

      assert Process.info(cache, [:dictionary, :messages, :backtrace]) ==
               [dictionary: [], messages: [], backtrace: ""]
    end

    test "TN-66: a cached key is in no ETS table and no persistent_term", %{cache: cache} do
      marker = :crypto.strong_rand_bytes(32)
      :ok = KeyCache.put(cache, :marker, Redacted.wrap(marker), KeyCache.generation(cache))

      for {_key, value} <- :persistent_term.get(),
          do: refute(:erlang.term_to_binary(value) =~ marker)

      for table <- :ets.all(), :ets.info(table, :protection) in [:public, :protected] do
        content =
          try do
            :ets.tab2list(table)
          rescue
            ArgumentError -> []
          end

        refute :erlang.term_to_binary(content) =~ marker, inspect(:ets.info(table, :name))
      end
    end
  end
end
