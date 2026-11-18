defmodule Relay.Migration.RulesTest do
  use ExUnit.Case, async: true

  alias Relay.Migration.Bucket
  alias Relay.Migration.Compare
  alias Relay.Migration.Content
  alias Relay.Migration.Ramp
  alias Relay.Migration.Routing
  alias Relay.Migration.Shadow

  @buckets "conformance/vectors/rollout-bucket/1/vectors.json"
  @contents "conformance/vectors/shadow-content/1/vectors.json"
  @now ~U[2026-11-18 12:00:00Z]

  defp read(path), do: path |> File.read!() |> Jason.decode!()

  defp uuid(text) do
    {:ok, binary} = Ecto.UUID.dump(text)
    binary
  end

  defp config(attrs) do
    Map.merge(
      %{
        emergency_stop: false,
        relay_list: MapSet.new(),
        legacy_list: MapSet.new(),
        enabled_categories: MapSet.new(["orders"]),
        basis_points: %{"orders" => 10_000}
      },
      attrs
    )
  end

  describe "OP-95 sticky bucket" do
    test "OP-95: the bucket and the digest follow the conformance vectors" do
      vectors = read(@buckets)
      tenant = uuid(vectors["tenant_id"])
      assert Bucket.buckets() == vectors["buckets"]

      for vector <- vectors["vectors"] do
        digest = Bucket.digest(tenant, vector["external_id"])
        assert Base.encode16(digest, case: :lower) == vector["digest"], vector["external_id"]
        assert Bucket.bucket(tenant, vector["external_id"]) == vector["bucket"]
      end
    end

    test "OP-53: the bucket of a recipient never changes and depends on the tenant" do
      tenant = uuid("0199f1c6-0000-7000-8000-000000000001")
      other = uuid("0199f1c6-0000-7000-8000-000000000002")

      for _round <- 1..3,
          do: assert(Bucket.bucket(tenant, "user-4821") == Bucket.bucket(tenant, "user-4821"))

      refute Bucket.digest(tenant, "user-4821") == Bucket.digest(other, "user-4821")
    end
  end

  describe "OP-53 routing order" do
    test "OP-53: emergency stop, pinned lists, enabled categories, then the bucket" do
      tenant = uuid("0199f1c6-0000-7000-8000-000000000001")
      pinned = MapSet.new([Bucket.digest(tenant, "user-4821")])

      assert Routing.route(nil, tenant, "orders", "user-4821") == :relay

      stopped = config(%{emergency_stop: true, relay_list: pinned})
      assert Routing.route(stopped, tenant, "orders", "user-4821") == :legacy

      relay = config(%{relay_list: pinned, legacy_list: pinned, enabled_categories: MapSet.new()})
      assert Routing.route(relay, tenant, "orders", "user-4821") == :relay

      legacy = config(%{legacy_list: pinned})
      assert Routing.route(legacy, tenant, "orders", "user-4821") == :legacy

      assert Routing.route(config(%{}), tenant, "marketing", "user-4821") == :legacy

      at_bucket = config(%{basis_points: %{"orders" => 1227}})
      above_bucket = config(%{basis_points: %{"orders" => 1228}})
      assert Routing.route(at_bucket, tenant, "orders", "user-4821") == :legacy
      assert Routing.route(above_bucket, tenant, "orders", "user-4821") == :relay
    end
  end

  describe "OP-53 ramp rule" do
    test "OP-53: a raise is at most five times the previous share with a floor of 1 percent" do
      assert {:ok, %{"orders" => %{"basis_points" => 100}}} =
               Ramp.check(%{}, %{"orders" => 100}, @now)

      assert {:error, [%{pointer: "/basis_points/orders", code: "not_allowed"}]} =
               Ramp.check(%{}, %{"orders" => 101}, @now)

      day_ago = DateTime.to_iso8601(DateTime.add(@now, -86_400))
      steps = %{"orders" => %{"basis_points" => 100, "changed_at" => day_ago}}

      assert {:ok, %{"orders" => %{"basis_points" => 500}}} =
               Ramp.check(steps, %{"orders" => 500}, @now)

      assert {:error, [_error]} = Ramp.check(steps, %{"orders" => 501}, @now)
      assert Ramp.ceiling(2500) == 10_000
    end

    test "OP-53: a raise needs a full day since the last change; a lowering is always allowed" do
      hour_ago = DateTime.to_iso8601(DateTime.add(@now, -3_600))
      steps = %{"orders" => %{"basis_points" => 500, "changed_at" => hour_ago}}

      assert {:error, [%{detail: detail}]} = Ramp.check(steps, %{"orders" => 600}, @now)
      assert detail =~ "one day"
      assert {:ok, %{"orders" => %{"basis_points" => 0}}} = Ramp.check(steps, %{}, @now)

      assert {:ok, %{"orders" => %{"basis_points" => 100}}} =
               Ramp.check(steps, %{"orders" => 100}, @now)

      assert {:ok, ^steps} = Ramp.check(steps, %{"orders" => 500}, @now)
    end
  end

  describe "OP-94 canonical content" do
    test "OP-94: the canonical form and digest follow the conformance vectors" do
      for vector <- read(@contents)["vectors"] do
        assert Content.canonical(vector["channel"], vector["content"]) == vector["canonical"]
        assert Content.digest(vector["channel"], vector["content"]) == vector["digest"]
      end
    end

    test "OP-52 (4): money and dates stay while timestamps, links and tokens are masked" do
      assert Content.mask("Tutar 1.250,00 TL, 18.11.2026") == "Tutar 1.250,00 TL, 18.11.2026"
      assert Content.mask("at 2026-11-18T09:30:00+03:00") == "at <ts>"
      assert Content.mask("https://x.example/a/b?sig=1#f") == "https://x.example/a/b"
    end
  end

  describe "OP-52 layered comparison" do
    @legacy %{
      "decision" => "sent",
      "consent" => "allowed",
      "timing" => "none",
      "dedup_key" => nil,
      "schedule" => nil,
      "content" => "c1",
      "provider" => "netgsm",
      "sender" => nil
    }
    @relay %{
      "decision" => "sent",
      "consent" => "allowed",
      "timing" => "none",
      "dedup_key" => "d",
      "schedule" => nil
    }

    test "OP-52 (4): equal sides match in every layer that can be compared" do
      delivery = Compare.delivery_side("c1", "netgsm", nil)

      assert %{state: :matched, decision_match: true, content_match: true, routing_match: true} =
               Compare.compare(@legacy, @relay, delivery)
    end

    test "OP-52 (4): decision, content and routing differences are named by field" do
      legacy = %{@legacy | "consent" => "refused", "decision" => "skipped"}
      delivery = Compare.delivery_side("c2", "verimor", nil)
      outcome = Compare.compare(legacy, @relay, delivery)

      assert outcome.state == :differs
      assert outcome.differing == ["decision", "consent", "provider"]
      assert outcome.unpermitted
      assert Compare.compare(@legacy, @relay, delivery).differing == ["content", "provider"]
    end

    test "OP-94: a side that never came is a recipient set difference once the grace ends" do
      assert %{state: :pending} = Compare.compare(@legacy, nil, nil)

      assert %{state: :differs, differing: ["recipients"]} =
               Compare.compare(nil, @relay, nil, true)
    end

    test "OP-94: Relay's decision side reads the consent and timing from the rule" do
      row = %{"decision" => "skip", "decision_rule_id" => "suppression.address"}

      assert %{"decision" => "skipped", "consent" => "suppressed", "timing" => "none"} =
               Compare.relay_side(row)

      deferred = %{"decision" => "defer", "decision_rule_id" => "quiet_hours.deferred"}

      assert %{"decision" => "deferred", "timing" => "quiet_hours"} =
               Compare.relay_side(deferred)
    end
  end

  describe "OP-79 exit criterion" do
    test "OP-79: every combination sufficient, two cycles observed and no unexplained difference" do
      row = %{"observed" => 100, "unexplained" => 0}
      small = %{"observed" => 3, "unexplained" => 0}
      first = DateTime.add(@now, -15 * 86_400)

      assert %{exit_criteria_met: true, cycles_met: true, days_observed: 15} =
               Shadow.report([row, small], first, 2, @now)

      recent = DateTime.add(@now, -3 * 86_400)
      report = Shadow.report([row, small], recent, 0, @now)
      refute report.exit_criteria_met
      assert [%{"sufficient" => true}, %{"sufficient" => false}] = report.rows

      refute Shadow.report([%{row | "unexplained" => 1}], first, 0, @now).exit_criteria_met
      refute Shadow.report([], first, 0, @now).exit_criteria_met
    end
  end
end
