defmodule Relay.EnvironmentRegionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Environment
  alias Relay.Region

  describe "TN-7 environments" do
    test "TN-7: there are exactly two environments and their text forms round-trip" do
      assert Environment.all() == [:live, :test]

      for environment <- Environment.all() do
        assert Environment.cast(Environment.dump(environment)) == {:ok, environment}
        assert Environment.cast(environment) == {:ok, environment}
      end
    end

    property "TN-7: any other value is refused" do
      check all value <- one_of([string(:printable), atom(:alphanumeric), integer()]),
                value not in ["live", "test", :live, :test] do
        assert {:error, %Relay.Error{code: :invalid_environment}} = Environment.cast(value)
      end
    end
  end

  describe "C-10 TN-2 regions" do
    test "C-10: the regions are tr, eu and us and their text forms round-trip" do
      assert Region.all() == [:tr, :eu, :us]

      for region <- Region.all() do
        assert Region.cast(Region.dump(region)) == {:ok, region}
        assert Region.cast(region) == {:ok, region}
      end
    end

    property "TN-2: any other value is refused" do
      check all value <- one_of([string(:printable), atom(:alphanumeric), integer()]),
                value not in ["tr", "eu", "us", :tr, :eu, :us] do
        assert {:error, %Relay.Error{code: :invalid_region}} = Region.cast(value)
      end
    end

    test "TN-2: upper-case region names are not regions" do
      assert {:error, _} = Region.cast("TR")
    end
  end
end
