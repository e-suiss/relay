defmodule Relay.Ingest.QuotaTest do
  use Relay.DataCase, async: true

  alias RelayTest.TenantFixture

  @vectors "test/vectors/quota/quota_v1.json" |> File.read!() |> Jason.decode!()

  defp policy(scope, policy) do
    {:ok, {:created, 1, false}} =
      Relay.Ingest.in_event_scope(scope, fn _status ->
        Relay.Ingest.quota_policy_set(
          %{
            period: policy["period"],
            limit_total: policy["limit_total"],
            class_caps: policy["class_caps"],
            security_reserve_bp: policy["security_reserve_bp"]
          },
          TenantFixture.digest(),
          TenantFixture.actor()
        )
      end)
  end

  defp consume(scope, class, count) do
    {:ok, rows} =
      Relay.Ingest.in_event_scope(scope, fn _status ->
        Relay.Ingest.quota_consume(class, count, :rand.uniform(16) - 1)
      end)

    rows
  end

  describe "API-51 TN-52 quota vectors" do
    test "API-79: the quota vectors give their results and first-time marks" do
      for v <- @vectors["vectors"] do
        scope = TenantFixture.tenant!().live
        if Map.get(v, "policy", @vectors["policy"]), do: policy(scope, @vectors["policy"])

        for [class, count] <- v["before"] do
          rows = consume(scope, class, count)
          assert Enum.all?(rows, &(&1["result"] in [:allowed, :reserve])), v["name"]
        end

        assert [row] = consume(scope, v["class"], v["count"])
        assert row["result"] == String.to_existing_atom(v["result"]), v["name"]
        assert row["marks"] == v["marks"], v["name"]
      end
    end

    test "TN-52: a threshold and the security reserve each raise one outbox event per period" do
      scope = TenantFixture.tenant!().live
      policy(scope, @vectors["policy"])
      consume(scope, "transactional", 1000)
      consume(scope, "security", 1)
      consume(scope, "security", 1)

      {:ok, types} =
        Relay.Repo.in_scope(scope, fn _status ->
          Relay.Repo.scoped_query!(
            "SELECT event_type FROM relay.outbox_events ORDER BY created_at, seq",
            []
          ).rows
        end)

      assert List.flatten(types) == [
               "quota.threshold_reached",
               "quota.threshold_reached",
               "quota.reserve_opened"
             ]
    end
  end
end
