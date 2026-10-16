defmodule Relay.Platform.SignalTest do
  use ExUnit.Case, async: true

  import Mox

  alias Relay.Platform.Signal
  alias Relay.Platform.Signal.Hub
  alias Relay.ValkeyMock

  setup :verify_on_exit!

  @hub :relay_signal_hub_test
  @poll_ms 20

  setup do
    allow(ValkeyMock, self(), fn -> GenServer.whereis(@hub) end)
    stub(ValkeyMock, :subscribe, fn _ -> :ok end)
    stub(ValkeyMock, :unsubscribe, fn _ -> :ok end)
    hub = start_supervised!({Hub, name: @hub, adapter: ValkeyMock, poll_interval_ms: @poll_ms})
    {:ok, topic} = Signal.topic("tnt_1", "live", ["inbox", "rcp_1"])
    %{hub: hub, topic: topic}
  end

  describe "INV-52 a signal carries only a sequence number" do
    test "INV-52: the published payload is the decimal sequence number and nothing else", %{
      topic: topic
    } do
      expect(ValkeyMock, :command, fn ["PUBLISH", ^topic, "42"] -> {:ok, 1} end)
      assert :ok = Signal.publish(topic, 42, ValkeyMock)
    end

    test "INV-52: publishing data instead of a sequence number is impossible", %{topic: topic} do
      for payload <- [%{body: "x"}, "42", -1, 1.0] do
        assert_raise FunctionClauseError, fn -> Signal.publish(topic, payload, ValkeyMock) end
      end
    end

    test "INV-52: a malformed payload only asks the subscriber to re-read" do
      assert Signal.decode("7") == {:seq, 7}
      assert Signal.decode("{\"body\":1}") == :poll
      assert Signal.decode("-1") == :poll
      assert Signal.decode("") == :poll
    end

    test "TN-17: topics are tenant and environment scoped", %{topic: topic} do
      assert topic == "relay:t:tnt_1:live:signal:inbox:rcp_1"
      assert {:error, %Relay.Error{}} = Signal.topic("tnt:1", "live", ["inbox"])
    end
  end

  describe "T-9 delivery and fallback" do
    test "T-10: a confirmed subscription forwards signals and asks for one catch-up read", %{
      hub: hub,
      topic: topic
    } do
      :ok = Signal.subscribe(topic, @hub)
      send(hub, {:valkey, :up, topic})
      assert %{^topic => :up} = Hub.topics(@hub)
      assert_received {:relay_signal, ^topic, :poll}
      flush(topic)

      send(hub, {:valkey, :message, topic, "5"})
      assert_receive {:relay_signal, ^topic, {:seq, 5}}

      refute_receive {:relay_signal, ^topic, :poll}, @poll_ms * 3
    end

    test "T-9: until the subscription is confirmed the subscriber polls", %{topic: topic} do
      :ok = Signal.subscribe(topic, @hub)
      assert_receive {:relay_signal, ^topic, :poll}, @poll_ms * 5
      assert_receive {:relay_signal, ^topic, :poll}, @poll_ms * 5
    end

    test "T-9: when Valkey goes down the subscriber falls back to short-interval polling", %{
      hub: hub,
      topic: topic
    } do
      :ok = Signal.subscribe(topic, @hub)
      send(hub, {:valkey, :up, topic})
      assert %{^topic => :up} = Hub.topics(@hub)
      flush(topic)
      refute_receive {:relay_signal, ^topic, :poll}, @poll_ms * 3

      send(hub, {:valkey, :down})
      assert_receive {:relay_signal, ^topic, :poll}, @poll_ms * 5
      assert_receive {:relay_signal, ^topic, :poll}, @poll_ms * 5
      assert Hub.topics(@hub) == %{topic => :pending}
    end

    test "T-10: after a reconnect the subscriber re-reads once and polling stops", %{
      hub: hub,
      topic: topic
    } do
      :ok = Signal.subscribe(topic, @hub)
      send(hub, {:valkey, :down})
      assert_receive {:relay_signal, ^topic, :poll}, @poll_ms * 5

      flush(topic)
      send(hub, {:valkey, :up, topic})
      assert Hub.topics(@hub) == %{topic => :up}
      assert_received {:relay_signal, ^topic, :poll}
      flush(topic)
      refute_receive {:relay_signal, ^topic, :poll}, @poll_ms * 3
    end

    test "T-9: a failed Valkey subscription still leaves the subscriber polling" do
      expect(ValkeyMock, :subscribe, fn _ -> {:error, %Redix.ConnectionError{reason: :closed}} end)

      {:ok, other} = Signal.topic("tnt_1", "live", ["other"])
      :ok = Signal.subscribe(other, @hub)
      assert_receive {:relay_signal, ^other, :poll}, @poll_ms * 5
      assert Hub.topics(@hub) == %{other => :pending}
    end

    test "T-9: one Valkey subscription serves every local subscriber of a topic", %{
      hub: hub,
      topic: topic
    } do
      test = self()

      stub(ValkeyMock, :subscribe, fn channel ->
        send(test, {:valkey_subscribe, channel})
        :ok
      end)

      {:ok, other} =
        Agent.start_link(fn ->
          :ok = Signal.subscribe(topic, @hub)
          test
        end)

      :ok = Signal.subscribe(topic, @hub)
      send(hub, {:valkey, :message, topic, "9"})
      assert_receive {:relay_signal, ^topic, {:seq, 9}}
      assert_received {:valkey_subscribe, ^topic}
      refute_received {:valkey_subscribe, ^topic}
      Agent.stop(other)
    end

    test "T-9: the subscription is released when the last subscriber leaves or exits", %{
      topic: topic
    } do
      expect(ValkeyMock, :unsubscribe, 1, fn ^topic -> :ok end)

      {:ok, other} = Agent.start(fn -> :ok = Signal.subscribe(topic, @hub) end)
      :ok = Signal.subscribe(topic, @hub)
      :ok = Signal.unsubscribe(topic, @hub)
      assert Map.has_key?(Hub.topics(@hub), topic)

      Agent.stop(other)
      wait_until(fn -> Hub.topics(@hub) == %{} end)
    end
  end

  defp flush(topic) do
    receive do
      {:relay_signal, ^topic, _} -> flush(topic)
    after
      0 -> :ok
    end
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not reached")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
