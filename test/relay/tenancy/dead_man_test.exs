defmodule Relay.Tenancy.DeadManTest do
  use ExUnit.Case, async: true

  alias Relay.Tenancy.DeadMan

  describe "TN-43 trip rule" do
    test "TN-43: the parameters are ten times the baseline rate, five and sixty minutes and a floor of 500" do
      assert DeadMan.params() == %{
               factor: 10,
               current_minutes: 5,
               baseline_minutes: 60,
               floor: 500
             }
    end

    test "TN-43: the switch trips above ten times the baseline rate and at the floor" do
      refute DeadMan.trip?({1_000, 1_200})
      refute DeadMan.trip?({1_000, 1_199 + 1})
      assert DeadMan.trip?({1_001, 1_200})
      assert DeadMan.trip?({600, 0})
      refute DeadMan.trip?({499, 0})
      assert DeadMan.trip?({500, 0})
    end

    test "TN-43: the reason names the ratio over the baseline" do
      assert DeadMan.reason({1_500, 1_200}) == "dead_man: 15.0× over 1h baseline"
      assert DeadMan.reason({600, 0}) == "dead_man: inf× over 1h baseline"
    end

    test "TN-43: tenant, campaign and workflow scopes have their own counter keys" do
      assert DeadMan.key(:tenant, nil) == "dms:tenant:tenant"
      assert DeadMan.key(:campaign, "cmp-1") == "dms:campaign:cmp-1"
      assert DeadMan.key(:workflow, "w") == "dms:workflow:w"
    end
  end
end
