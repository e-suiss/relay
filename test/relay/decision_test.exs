defmodule Relay.DecisionTest do
  use ExUnit.Case, async: true

  alias Relay.Decision

  test "T-58: a skip is a result with a reason and rule id, not an error" do
    assert {:skip, :quiet_hours, "PC-46"} = Decision.skip(:quiet_hours, "PC-46")
    assert Decision.skip?(Decision.skip(:quiet_hours, "PC-46"))
    refute Decision.skip?(Decision.send(:email))
  end

  test "T-58: a skip without a rule id is refused" do
    assert_raise FunctionClauseError, fn -> Decision.skip(:quiet_hours, "") end
  end

  test "T-58: errors are typed structs" do
    assert %Relay.Error{code: :not_ready, details: %{}} = Relay.Error.new(:not_ready, "not ready")
  end
end
