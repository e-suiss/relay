defmodule Relay.Devices.PresenceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Relay.Devices.Badge
  alias Relay.Devices.Presence

  defp scope, do: Relay.Scope.new!(Relay.Id.generate(), :live)

  describe "IN-53 break transitions" do
    test "IN-53, WF-56: break set, focus ended and screen unlocked are the break transitions" do
      assert Presence.break?(%{}, %{"break" => true})
      assert Presence.break?(%{"break" => {false, 1}}, %{"break" => true})
      refute Presence.break?(%{"break" => {true, 1}}, %{"break" => true})
      assert Presence.break?(%{"focus" => {true, 1}}, %{"focus" => false})
      refute Presence.break?(%{}, %{"focus" => false})
      assert Presence.break?(%{"locked" => {true, 1}}, %{"locked" => false})
      refute Presence.break?(%{"locked" => {false, 1}}, %{"locked" => false})
      refute Presence.break?(%{"worn" => {true, 1}}, %{"worn" => false, "headphones" => true})
    end
  end

  describe "IN-47 short-lived record" do
    test "IN-47, IN-53: a write keeps its signals for their time to live, then they are unknown" do
      scope = scope()
      device = Relay.Id.generate()

      assert {:ok, %{break: false, signals: signals}} =
               Presence.write(scope, device, %{"locked" => true}, 150)

      assert signals["locked"] == true
      assert signals["worn"] == :unknown
      assert Presence.read(scope, device)["locked"] == true

      Process.sleep(300)
      assert Presence.read(scope, device) == Map.new(Presence.signals("v1"), &{&1, :unknown})
    end

    test "IN-53: a device writes once a second and a later write merges the changed keys" do
      scope = scope()
      device = Relay.Id.generate()

      assert {:ok, _written} = Presence.write(scope, device, %{"focus" => true}, 60_000)
      assert {:error, :rate_limited} = Presence.write(scope, device, %{"focus" => false}, 60_000)

      Process.sleep(1_100)

      assert {:ok, %{break: true, signals: signals}} =
               Presence.write(scope, device, %{"focus" => false, "worn" => true}, 60_000)

      assert %{"focus" => false, "worn" => true, "locked" => :unknown} = signals
    end

    test "IN-53: the time to live is cut at PT15M" do
      assert Presence.max_ttl_ms() == 900_000
      assert Presence.default_ttl_ms() == 300_000
      assert Presence.signals("v1") == ~w(break focus headphones locked worn)
      assert Presence.signals("v2") == nil
    end

    test "IN-48: a status write and read log nothing" do
      scope = scope()
      device = Relay.Id.generate()

      log =
        capture_log([level: :debug], fn ->
          {:ok, _written} = Presence.write(scope, device, %{"headphones" => true}, 60_000)
          Presence.read(scope, device)
        end)

      refute log =~ "headphones"
    end
  end

  describe "IN-20 badge" do
    test "IN-20: iOS caps at 999 and leaves an uncertain count out, Android and Web take it" do
      assert Badge.members("apns", 1_500) == %{"badge" => 999}
      assert Badge.members("apns", 7) == %{"badge" => 7}
      assert Badge.members("apns", nil) == %{}
      assert Badge.members("fcm", 1_500) == %{"notification_count" => 1_500}
      assert Badge.members("hms", 3) == %{"notification_count" => 3}
      assert Badge.members("web_push", 12) == %{"badge" => 12}
      assert Badge.members("unified_push", 12) == %{}
    end

    test "IN-18, IN-20: the count is the counter write's own unseen or unread number" do
      counters = %{unseen: 4, unread: 9, version: 31}
      assert Badge.count(counters) == 4
      assert Badge.count(counters, :unread) == 9
      assert Badge.count(Map.put(counters, :uncertain, true)) == nil
      assert Relay.Devices.badge("apns", counters) == %{"badge" => 4}
      assert Relay.Devices.badge("apns", %{uncertain: true, unseen: 4}) == %{}
    end
  end
end
