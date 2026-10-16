defmodule Relay.Platform.ValkeyTest do
  use ExUnit.Case, async: true

  import Mox

  alias Relay.Platform.Valkey
  alias Relay.Platform.Valkey.Key
  alias Relay.ValkeyMock

  setup :verify_on_exit!

  setup do
    {:ok, key} = Key.new("tnt_1", "live", ["entry"], 30_000)
    %{key: key}
  end

  test "T-9: a stored value always carries the key's TTL", %{key: key} do
    expect(ValkeyMock, :command, fn ["SET", "relay:t:tnt_1:live:entry", "v", "PX", "30000"] ->
      {:ok, "OK"}
    end)

    assert :ok = Valkey.put(key, "v", ValkeyMock)
  end

  test "T-9: a missing entry reads as nil", %{key: key} do
    expect(ValkeyMock, :command, fn ["GET", "relay:t:tnt_1:live:entry"] -> {:ok, nil} end)
    assert {:ok, nil} = Valkey.get(key, ValkeyMock)
  end

  test "T-9: an unavailable Valkey is a typed error, never an exception", %{key: key} do
    stub(ValkeyMock, :command, fn _ -> {:error, %Redix.ConnectionError{reason: :closed}} end)

    assert {:error, %Relay.Error{code: :valkey_unavailable, details: %{reason: :closed}}} =
             Valkey.put(key, "v", ValkeyMock)

    assert {:error, %Relay.Error{code: :valkey_unavailable}} = Valkey.get(key, ValkeyMock)

    assert {:error, %Relay.Error{code: :valkey_unavailable}} =
             Valkey.publish("relay:s:x", "1", ValkeyMock)
  end

  test "T-10: several messages publish in one pipeline" do
    expect(ValkeyMock, :pipeline, fn [["PUBLISH", "ch", "a"], ["PUBLISH", "ch", "b"]] ->
      {:ok, [1, 1]}
    end)

    assert :ok = Valkey.publish_many("ch", ["a", "b"], ValkeyMock)
    assert :ok = Valkey.publish_many("ch", [], ValkeyMock)
  end

  test "T-10: a server error inside the pipeline is reported" do
    expect(ValkeyMock, :pipeline, fn _ -> {:ok, [1, %Redix.Error{message: "ERR"}]} end)

    assert {:error, %Relay.Error{code: :valkey_reply}} =
             Valkey.publish_many("ch", ["a", "b"], ValkeyMock)
  end

  test "T-9: the eviction policy is read from INFO memory" do
    expect(ValkeyMock, :command, fn ["INFO", "memory"] ->
      {:ok, "# Memory\r\nused_memory:1\r\nmaxmemory_policy:noeviction\r\n"}
    end)

    assert {:ok, "noeviction"} = Valkey.eviction_policy(ValkeyMock)
  end

  test "T-9: subscribing goes through the adapter for the calling process" do
    test = self()

    expect(ValkeyMock, :subscribe, fn "ch" ->
      send(test, {:subscribed_by, self()})
      :ok
    end)

    expect(ValkeyMock, :unsubscribe, fn "ch" -> :ok end)

    assert :ok = Valkey.subscribe("ch", ValkeyMock)
    assert_received {:subscribed_by, ^test}
    assert :ok = Valkey.unsubscribe("ch", ValkeyMock)
  end
end
