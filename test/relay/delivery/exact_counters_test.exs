defmodule Relay.Delivery.ExactCountersTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @probabilistic ~r/\b(bloom|hyperloglog|hll|count_min|cuckoo)\b/i

  defp sources do
    ["lib/**/*.ex", "priv/repo/**/*.{exs,sql}", "native/*/src/**/*.rs", "mix.exs", "mix.lock"]
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
  end

  describe "DS-39 exact counters" do
    test "DS-39: no probabilistic structure is in the application, its schema or its dependencies" do
      offenders = for file <- sources(), File.read!(file) =~ @probabilistic, do: file
      assert offenders == []
    end

    test "DS-39, OP-38: usage rows count attempts and deliveries exactly in Postgres" do
      source = File.read!(Path.join(@root, "lib/relay/delivery/usage/store.ex"))
      assert source =~ "count(DISTINCT a.delivery_id) AS quantity, count(*) AS attempt_count"
    end
  end
end
