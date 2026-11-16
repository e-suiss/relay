defmodule Relay.Webhooks.TokenCacheTest do
  use ExUnit.Case, async: false

  import Mox

  alias Relay.Redacted
  alias Relay.Webhooks.TokenCache

  setup :verify_on_exit!

  setup do
    previous = Application.fetch_env!(:relay, :clock)
    Application.put_env(:relay, :clock, Relay.ClockMock)
    on_exit(fn -> Application.put_env(:relay, :clock, previous) end)

    now = :counters.new(1, [])
    stub(Relay.ClockMock, :monotonic_ms, fn -> :counters.get(now, 1) end)
    cache = start_supervised!({TokenCache, name: nil, max_entries: 2, sweep_ms: 3_600_000})
    allow(Relay.ClockMock, self(), cache)
    %{cache: cache, now: now}
  end

  defp at(now, seconds), do: :counters.put(now, 1, seconds * 1000)

  defp fetch(value, lifetime_s) do
    test = self()

    fn ->
      send(test, {:fetched, value})
      {:ok, Redacted.wrap(value), lifetime_s}
    end
  end

  defp exposed({:ok, value}), do: Redacted.expose(value)

  describe "WH-19 the cache of derived credentials" do
    test "WH-19: a value is fetched once and served from the cache while it lives", ctx do
      %{cache: cache, now: now} = ctx

      assert exposed(TokenCache.through(cache, :k, fetch("tok-1", 3600), 300)) == "tok-1"
      assert_received {:fetched, "tok-1"}

      at(now, 299)
      assert exposed(TokenCache.through(cache, :k, fetch("tok-2", 3600), 300)) == "tok-1"
      refute_received {:fetched, _value}

      at(now, 300)
      assert exposed(TokenCache.through(cache, :k, fetch("tok-2", 3600), 300)) == "tok-2"
      assert_received {:fetched, "tok-2"}
    end

    test "WH-19: a value lives for its lifetime less a margin, never longer than the ceiling, and not at all without a lifetime",
         %{cache: cache} do
      assert TokenCache.ttl_s(3600, 300) == 300
      assert TokenCache.ttl_s(100, 300) == 70
      assert TokenCache.ttl_s(30, 300) == 0
      assert TokenCache.ttl_s(nil, 300) == 0

      assert exposed(TokenCache.through(cache, :k, fetch("short", 20), 300)) == "short"
      assert exposed(TokenCache.through(cache, :k, fetch("unknown", nil), 300)) == "unknown"
      assert TokenCache.size(cache) == 0
      assert TokenCache.fetch(cache, :k) == :miss
    end

    test "WH-19: the cache holds a bounded number of values: the expired go first, then the one that expires soonest",
         %{cache: cache, now: now} do
      :ok = TokenCache.put(cache, :a, Redacted.wrap("a"), 10)
      :ok = TokenCache.put(cache, :b, Redacted.wrap("b"), 100)
      :ok = TokenCache.put(cache, :c, Redacted.wrap("c"), 50)

      assert TokenCache.size(cache) == 2
      assert TokenCache.fetch(cache, :a) == :miss
      assert exposed(TokenCache.fetch(cache, :b)) == "b"
      assert exposed(TokenCache.fetch(cache, :c)) == "c"

      at(now, 60)
      :ok = TokenCache.put(cache, :d, Redacted.wrap("d"), 10)
      assert TokenCache.size(cache) == 2
      assert TokenCache.fetch(cache, :c) == :miss
      assert exposed(TokenCache.fetch(cache, :b)) == "b"
      assert exposed(TokenCache.fetch(cache, :d)) == "d"
    end

    test "WH-19: a refused value is dropped and a failed fetch keeps nothing", %{cache: cache} do
      assert {:ok, _value} = TokenCache.through(cache, :k, fetch("tok-1", 3600), 300)
      assert :ok = TokenCache.drop(cache, :k)
      assert TokenCache.fetch(cache, :k) == :miss

      failure = %{class: :credentials, reason: "token_endpoint_refused"}
      assert {:error, ^failure} = TokenCache.through(cache, :k, fn -> {:error, failure} end, 300)
      assert TokenCache.size(cache) == 0
    end

    test "TN-17: the key of an endpoint's value carries the tenant, the environment, the endpoint version and the secret reference" do
      endpoint = %{"id" => <<1::128>>, "version" => 3, "credential_ref_id" => <<2::128>>}
      live = Relay.Scope.new!(<<7::128>>, :live)
      test = Relay.Scope.new!(<<7::128>>, :test)
      other = Relay.Scope.new!(<<8::128>>, :live)

      key = TokenCache.key(live, endpoint)
      assert key != TokenCache.key(test, endpoint)
      assert key != TokenCache.key(other, endpoint)
      assert key != TokenCache.key(live, %{endpoint | "version" => 4})
      assert key != TokenCache.key(live, %{endpoint | "credential_ref_id" => <<3::128>>})
      assert key == TokenCache.key(live, endpoint)
    end

    test "T-46, TN-26 (3): the process shows how many values it holds and never a value", ctx do
      :ok = TokenCache.put(ctx.cache, :k, Redacted.wrap("tok-secret-value"), 100)

      refute inspect(:sys.get_status(ctx.cache), limit: :infinity) =~ "tok-secret-value"
      state = %TokenCache{entries: %{k: {Redacted.wrap("tok-secret-value"), 0}}}
      refute inspect(state, limit: :infinity) =~ "tok-secret-value"
      assert Relay.Hygiene.check_inspect(TokenCache, [:entries]) == :ok
      refute File.read!("lib/relay/webhooks/token_cache.ex") =~ ~r/:ets\.|:persistent_term\./
    end

    test "WH-19: a cache that is not running is a miss and the fetch still answers" do
      assert TokenCache.fetch(:relay_token_cache_not_running, :k) == :miss
      cache = :relay_token_cache_not_running
      assert {:ok, _value} = TokenCache.through(cache, :k, fetch("tok-1", 3600), 300)
    end
  end
end
