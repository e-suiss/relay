defmodule Relay.Platform.LoadShedParamsTest do
  use ExUnit.Case, async: true

  alias Relay.Platform.Lane
  alias Relay.Platform.LoadShed

  describe "T-34 T-89 T-61 load shedding parameters" do
    test "T-89: the CoDel parameters of every lane are the golden values" do
      lines =
        for lane <- Lane.all() do
          p = LoadShed.params(lane)

          "#{lane} target_ms=#{p.target_ms} interval_ms=#{p.interval_ms} action=#{p.action} rule_id=#{p.rule_id}\n"
        end

      Relay.Golden.assert_golden("load_shed_params.txt", lines)
    end

    test "T-34 (1): the targets grow from l0 to l3 and every rule is a valid rule id" do
      targets = Enum.map(Lane.all(), &LoadShed.params(&1).target_ms)
      assert targets == Enum.sort(targets)

      for lane <- Lane.all(),
          do: assert(LoadShed.params(lane).rule_id =~ ~r/^[a-z][a-z0-9_]*([.:][A-Za-z0-9_-]+)*$/)
    end
  end
end
