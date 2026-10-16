defmodule Relay.Tenancy.SettingsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  defp settings,
    do: map_of(string(?a..?f, min_length: 1, max_length: 2), term(), max_length: 8)

  describe "TN-3 TN-4 inheritance" do
    property "TN-4: a setting the sub-tenant defines always wins" do
      check all subtenant <- settings(), tenant <- settings() do
        resolved = Relay.Tenancy.resolve_settings(subtenant, tenant)

        for {key, value} <- subtenant do
          assert Map.fetch!(resolved, key) === value
          assert Relay.Tenancy.fetch_setting(subtenant, tenant, key) == {:ok, value, :subtenant}
        end
      end
    end

    property "TN-4: a setting the sub-tenant does not define comes from the tenant" do
      check all subtenant <- settings(), tenant <- settings() do
        resolved = Relay.Tenancy.resolve_settings(subtenant, tenant)

        for {key, value} <- tenant, not Map.has_key?(subtenant, key) do
          assert Map.fetch!(resolved, key) === value
          assert Relay.Tenancy.fetch_setting(subtenant, tenant, key) == {:ok, value, :tenant}
        end

        assert MapSet.new(Map.keys(resolved)) ==
                 MapSet.union(MapSet.new(Map.keys(subtenant)), MapSet.new(Map.keys(tenant)))
      end
    end

    property "TN-4: changing the tenant never changes a setting the sub-tenant defines" do
      check all subtenant <- settings(), before <- settings(), later <- settings() do
        a = Relay.Tenancy.resolve_settings(subtenant, before)
        b = Relay.Tenancy.resolve_settings(subtenant, later)

        assert Map.take(a, Map.keys(subtenant)) === Map.take(b, Map.keys(subtenant))
      end
    end

    test "TN-4: a present nil is a defined setting and is not replaced" do
      assert Relay.Tenancy.resolve_settings(%{logo: nil}, %{logo: "tenant.png"}) == %{logo: nil}

      assert Relay.Tenancy.fetch_setting(%{logo: nil}, %{logo: "tenant.png"}, :logo) ==
               {:ok, nil, :subtenant}
    end

    property "TN-3: without a sub-tenant the tenant settings apply unchanged" do
      check all tenant <- settings() do
        assert Relay.Tenancy.resolve_settings(nil, tenant) == tenant
        assert Relay.Tenancy.resolve_settings(%{}, tenant) == tenant
      end
    end

    test "TN-3: resolution has two levels and a missing setting is reported" do
      assert Relay.Tenancy.fetch_setting(nil, %{}, :logo) == :error
      assert Relay.Tenancy.fetch_setting(%{}, %{}, :logo) == :error
      assert_raise FunctionClauseError, fn -> Relay.Tenancy.resolve_settings(%{}, nil) end
    end
  end
end
