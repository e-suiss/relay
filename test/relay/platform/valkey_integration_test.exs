defmodule Relay.Platform.ValkeyIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Relay.Platform.Queue.Notifier
  alias Relay.Platform.Signal
  alias Relay.Platform.Signal.Hub
  alias Relay.Platform.Valkey
  alias Relay.Platform.Valkey.Guard
  alias Relay.Platform.Valkey.Key

  @oban Relay.Platform.ValkeyIntegrationTest.Oban

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  defp eventually(fun, attempts \\ 100) do
    case fun.() do
      result when result in [false, nil] and attempts > 0 ->
        Process.sleep(50)
        eventually(fun, attempts - 1)

      result when result in [false, nil] ->
        flunk("condition not reached")

      result ->
        result
    end
  end

  defp kill_pubsub_clients do
    {:ok, killed} = Valkey.adapter().command(["CLIENT", "KILL", "TYPE", "pubsub"])
    assert killed >= 1
  end

  describe "T-9 Valkey rules against a real server" do
    test "T-9: the server runs with the noeviction policy and the guard confirms it" do
      assert {:ok, "noeviction"} = Valkey.eviction_policy()
      eventually(fn -> Guard.status() == :ok end)
    end

    test "T-9: a stored value expires with the key's TTL" do
      {:ok, key} = Key.new("tnt_#{unique()}", "test", ["entry"], 60_000)
      assert :ok = Valkey.put(key, "v")
      assert {:ok, "v"} = Valkey.get(key)
      assert {:ok, ttl} = Valkey.adapter().command(["PTTL", key.name])
      assert ttl > 0 and ttl <= 60_000
    end
  end

  describe "T-10 signals over Valkey pub/sub" do
    setup do
      {:ok, topic} = Signal.topic("tnt_#{unique()}", "test", ["inbox"])
      :ok = Signal.subscribe(topic)
      on_exit(fn -> Signal.unsubscribe(topic, Hub) end)
      eventually(fn -> Hub.topics(Hub)[topic] == :up end)
      %{topic: topic}
    end

    test "INV-52: a published signal arrives carrying only its sequence number", %{topic: topic} do
      assert :ok = Signal.publish(topic, 11)
      assert_receive {:relay_signal, ^topic, {:seq, 11}}, 1_000
    end

    test "T-10: after the pub/sub connection is lost the subscriber polls, then signals resume",
         %{topic: topic} do
      kill_pubsub_clients()
      eventually(fn -> Hub.topics(Hub)[topic] == :up end)
      assert_receive {:relay_signal, ^topic, :poll}, 2_000

      eventually(fn ->
        :ok = Signal.publish(topic, 12)

        receive do
          {:relay_signal, ^topic, {:seq, 12}} -> true
        after
          100 -> false
        end
      end)
    end
  end

  describe "T-55 queue notifier over a real Valkey" do
    setup do
      conf =
        Oban.Config.new(
          name: @oban,
          repo: Relay.Repo,
          prefix: "relay_queue",
          testing: :manual,
          notifier: {Notifier, []}
        )

      start_supervised!(%{
        id: Notifier,
        start:
          {Notifier, :start_link, [[conf: conf, name: Oban.Registry.via(@oban, Oban.Notifier)]]}
      })

      :ok = Oban.Notifier.listen(conf, [:gossip])
      %{conf: conf}
    end

    defp roundtrip(conf, marker) do
      eventually(fn ->
        _ = Oban.Notifier.notify(conf, :gossip, %{marker: marker})

        receive do
          {:notification, :gossip, %{"marker" => ^marker}} -> true
        after
          100 -> false
        end
      end)
    end

    test "T-55: a notification travels through Valkey to the listener", %{conf: conf} do
      roundtrip(conf, "first")
    end

    test "T-55: notifications resume after the Valkey connection is lost", %{conf: conf} do
      roundtrip(conf, "before")
      kill_pubsub_clients()
      roundtrip(conf, "after")
    end
  end
end
