defmodule Relay.Platform.JitterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Platform.Jitter

  @vectors "test/vectors/jitter/v1.json" |> File.read!() |> Jason.decode!()
  @two_64 Integer.pow(2, 64)

  defp uuid(text) do
    {:ok, id} = Relay.Id.parse(text)
    id
  end

  defp vector(id), do: Enum.find(@vectors["vectors"], &(&1["id"] == id))

  defp derived(%{"purpose" => "backoff", "parts" => [t, e, d, n], "params" => p}),
    do: Jitter.backoff(uuid(t), env(e), uuid(d), n, p["base_ms"], p["cap_ms"])

  defp derived(%{"purpose" => "retry_after", "parts" => [t, e, d, n], "params" => p}),
    do: Jitter.retry_after(uuid(t), env(e), uuid(d), n, p["ra_ms"])

  defp derived(%{"purpose" => "canary", "parts" => [t, e, n]}),
    do: Jitter.canary_bucket(uuid(t), env(e), uuid(n))

  defp derived(%{"purpose" => "breaker_open", "parts" => [node, key, count], "params" => p}),
    do: Jitter.breaker_open(node, key, count, p["open_ms"], p["jitter_bp"])

  defp env(text) do
    {:ok, environment} = Relay.Environment.cast(text)
    environment
  end

  describe "T-30 T-91 deterministic digest" do
    test "T-91: the vectors hash the deterministic CBOR input with SHA-256" do
      assert @vectors["version"] == "relay.jitter.v1"
      assert Enum.map(@vectors["vectors"], & &1["id"]) == ~w(J1 J2 J3 J4 J5)

      for v <- @vectors["vectors"] do
        input = Jitter.digest_input(v["purpose"], v["parts"])
        assert Base.encode16(input, case: :lower) == v["cbor"], v["id"]

        assert Base.encode16(:crypto.hash(:sha256, input), case: :lower) == v["sha256"],
               v["id"]

        assert Integer.to_string(Jitter.h(v["purpose"], v["parts"])) == v["h"], v["id"]
      end
    end

    test "T-30: the derived functions give the vector results" do
      for v <- @vectors["vectors"], do: assert(derived(v) == v["result"], v["id"])
    end

    test "T-30: scale keeps its boundary values" do
      for v <- @vectors["scale_vectors"],
          do: assert(Jitter.scale(String.to_integer(v["h"]), v["n"]) == v["result"])
    end

    test "T-26: the backoff range is capped and starts at the base" do
      j1 = vector("J1")
      [t, e, d, _] = j1["parts"]

      for n <- 1..70 do
        sleep = Jitter.backoff(uuid(t), env(e), uuid(d), n, 1_800_000, 7_200_000)
        assert sleep in 0..min(7_200_000, 1_800_000 * Integer.pow(2, n - 1))
      end
    end

    test "CH-9: a Retry-After wait adds between 0 and 20 percent" do
      [t, e, d, _] = vector("J3")["parts"]

      for n <- 1..50 do
        wait = Jitter.retry_after(uuid(t), env(e), uuid(d), n, 10_000)
        assert wait in 10_000..12_000
      end
    end

    test "T-30: the canary decision follows the bucket" do
      [t, e, n] = vector("J4")["parts"]
      assert Jitter.canary?(uuid(t), env(e), uuid(n), 16)
      refute Jitter.canary?(uuid(t), env(e), uuid(n), 15)
      refute Jitter.canary?(uuid(t), env(e), uuid(n), 0)
      assert Jitter.canary?(uuid(t), env(e), uuid(n), 100)
    end

    test "T-30: window offsets, snoozes and crash backoffs stay in range and repeat" do
      offset = Jitter.window_offset("rl.provider:apns", 3_600_000)
      assert offset in 0..3_599_999
      assert Jitter.window_offset("rl.provider:apns", 3_600_000) == offset

      [t, e, _, _] = vector("J1")["parts"]
      snooze = Jitter.snooze(uuid(t), env(e), "oban:42", 1, 5_000)
      assert snooze in 5_000..6_000
      assert Jitter.snooze(uuid(t), env(e), "oban:42", 1, 5_000) == snooze

      for attempt <- 0..40,
          do: assert(Jitter.crash_backoff(42, attempt) in 0..min(300_000, 1000 * 2 ** attempt))
    end

    test "T-30: the environment and the purpose separate digests" do
      [t, _, d, _] = vector("J1")["parts"]

      refute Jitter.h("backoff", [t, "live", d, 1]) == Jitter.h("backoff", [t, "test", d, 1])
      refute Jitter.h("backoff", [t, "live", d, 1]) == Jitter.h("retry_after", [t, "live", d, 1])
    end

    property "T-30: scale maps every digest onto [0, n)" do
      check all h <- integer(0..(@two_64 - 1)), n <- positive_integer() do
        assert Jitter.scale(h, n) in 0..(n - 1)
      end
    end

    test "T-30: scale refuses digests outside 64 bits and an empty range" do
      assert_raise FunctionClauseError, fn -> Jitter.scale(@two_64, 5) end
      assert_raise FunctionClauseError, fn -> Jitter.scale(1, 0) end
    end
  end
end
