defmodule Relay.Platform.Valkey.KeyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Platform.Valkey.Key

  describe "TN-17 tenant-scoped names" do
    test "TN-17: every tenant key carries the tenant and environment prefix" do
      assert {:ok, %Key{name: "relay:t:tnt_1:live:counter:sms", ttl_ms: 60_000}} =
               Key.new("tnt_1", "live", ["counter", "sms"], 60_000)
    end

    test "TN-17: tenant channels carry the same prefix" do
      assert {:ok, "relay:t:tnt_1:test:inbox"} = Key.channel("tnt_1", "test", ["inbox"])
    end

    test "TN-17: separators and empty segments from tenant data are refused" do
      for {tenant, env, segments} <- [
            {"tnt:1", "live", ["a"]},
            {"tnt_1", "", ["a"]},
            {"tnt_1", "live", []},
            {"tnt_1", "live", ["a b"]},
            {"tnt_1", "live", ["*"]},
            {"tnt_1", "live", [:atom]},
            {String.duplicate("a", 129), "live", ["a"]}
          ] do
        assert {:error, %Relay.Error{code: :invalid_key}} = Key.new(tenant, env, segments, 1_000)
        assert {:error, %Relay.Error{code: :invalid_key}} = Key.channel(tenant, env, segments)
      end
    end

    property "TN-17: two different tenants never share a key" do
      check all a <- string(:alphanumeric, min_length: 1, max_length: 16),
                b <- string(:alphanumeric, min_length: 1, max_length: 16),
                a != b do
        {:ok, ka} = Key.new(a, "live", ["x"], 1_000)
        {:ok, kb} = Key.new(b, "live", ["x"], 1_000)
        assert ka.name != kb.name
      end
    end

    test "TN-17: system channels cannot collide with tenant names" do
      system = Key.system_channel(["oban", "oban", "insert"])
      assert system == "relay:s:oban:oban:insert"
      {:ok, tenant} = Key.channel("s", "oban", ["oban", "insert"])
      refute tenant == system
      assert_raise ArgumentError, fn -> Key.system_channel(["bad:segment"]) end
    end

    test "TN-17: names are binaries; no atom is created from tenant data" do
      tenant = "tnt_never_an_atom_#{System.unique_integer([:positive])}"
      {:ok, key} = Key.new(tenant, "live", ["x"], 1_000)
      assert is_binary(key.name)
      assert_raise ArgumentError, fn -> String.to_existing_atom(tenant) end
    end
  end

  describe "T-9 (7) keys expire" do
    test "T-9: a key without a positive TTL is refused" do
      for ttl <- [0, -1, nil, :infinity, 1.5] do
        assert {:error, %Relay.Error{code: :invalid_key}} = Key.new("tnt_1", "live", ["a"], ttl)
      end
    end
  end
end
