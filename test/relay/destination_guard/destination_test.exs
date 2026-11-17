defmodule Relay.DestinationGuard.DestinationTest do
  use ExUnit.Case, async: true

  alias Relay.DestinationGuard
  alias Relay.DestinationGuard.Destination

  @prefix %{min_volume: 60, multiplier: 10, window_s: 600, baseline_window_s: 86_400}
  @country %{min_volume: 1_000, multiplier: 20, window_s: 600, baseline_window_s: 86_400}

  describe "CH-54 destination of a number" do
    test "CH-54: the country comes from the calling code and the shared codes are split" do
      assert Destination.country("+905551112233") == "TR"
      assert Destination.country("+4915112345678") == "DE"
      assert Destination.country("+12125550100") == "US"
      assert Destination.country("+18765550100") == "JM"
      assert Destination.country("+18095550100") == "DO"
      assert Destination.country("+77011234567") == "KZ"
      assert Destination.country("+79161234567") == "RU"
      assert Destination.country("+8881234567") == nil
    end

    test "CH-54: a number block is the number without its last digits" do
      assert Destination.block("+905551112233", 3) == "+905551112"
      assert Destination.block("+905551112233", 2) == "+9055511122"
      assert Destination.block("+9012", 3) == "+90"
    end

    test "CH-54: only an E.164 number can be placed" do
      assert Destination.number?("+905551112233")
      refute Destination.number?("05551112233")
      refute Destination.number?("+90")
      refute Destination.number?(nil)
    end
  end

  describe "CH-54 country allow-list" do
    test "CH-54: the default is the tenant's region" do
      assert Destination.region_countries(:tr) == ["TR"]
      assert Destination.region_countries(:us) == ["US"]
      assert "DE" in Destination.region_countries(:eu)
      assert "NO" in Destination.region_countries(:eu)
      refute "GB" in Destination.region_countries(:eu)
      refute "TR" in Destination.region_countries(:eu)
    end

    test "CH-54: a country is allowed in the region or when the tenant added it" do
      assert Destination.allowed?("TR", :tr, [])
      refute Destination.allowed?("DE", :tr, [])
      assert Destination.allowed?("DE", :tr, ["AZ", "DE"])
      assert Destination.allowed?("FR", :eu, [])
      refute Destination.allowed?("JM", :us, [])
    end

    test "CH-54: a number without a country is never allowed" do
      refute Destination.allowed?(nil, :tr, ["TR", "DE"])
    end
  end

  describe "CH-54 pumping anomaly" do
    test "CH-54: without a baseline the minimum volume is the threshold" do
      assert Destination.threshold(0, @prefix) == 60
      assert Destination.threshold(60, @prefix) == 60
      refute Destination.anomaly?(59, 59, @prefix)
      assert Destination.anomaly?(60, 60, @prefix)
    end

    test "CH-54: the threshold follows the tenant's own baseline for the destination" do
      assert Destination.threshold(100_000, @prefix) == 6_945
      refute Destination.anomaly?(60, 100_000, @prefix)
      refute Destination.anomaly?(6_944, 100_000, @prefix)
      assert Destination.anomaly?(6_945, 100_000, @prefix)

      assert Destination.threshold(1_000_000, @country) == 138_889
      refute Destination.anomaly?(20_000, 1_000_000, @country)
      assert Destination.anomaly?(1_000, 1_000, @country)
    end

    test "CH-54: the policy defaults are the contract's limits" do
      limits = Relay.Limits.fetch!(["sms_destination"])
      policy = DestinationGuard.limits()

      assert policy.block_digits == limits["block_digits"]
      assert policy.number.limit == limits["number_rate"]["limit"]
      assert policy.prefix.limit == limits["prefix_rate"]["limit"]
      assert policy.pumping.prefix.min_volume == limits["pumping"]["prefix"]["min_volume"]
      assert policy.pumping.country.multiplier == limits["pumping"]["country"]["multiplier"]
      assert policy.pumping.prefix == @prefix
      assert policy.pumping.country == @country
      assert policy.pumping.window_s == 600
      assert policy.pumping.baseline_window_s == 86_400
      assert policy.pumping.lift_grace_s == 600
      assert policy.pumping.escalation == %{prefix_stops: 5, window_s: 3_600}
    end
  end
end
