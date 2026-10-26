defmodule Relay.Platform.Queue.ObanSetupTest do
  use ExUnit.Case, async: true

  alias Relay.Platform.Queue
  alias Relay.Platform.Queue.Pruner

  @config Application.compile_env!(:relay, Oban)

  describe "T-17 T-12 queue setup" do
    test "T-17: the queue lives in relay_queue and inserts through the application repository" do
      assert @config[:prefix] == "relay_queue"
      assert @config[:repo] == Relay.Repo
    end

    test "T-12: leadership runs through Relay's peer on the queue role" do
      assert @config[:peer] == Relay.Platform.Queue.Peer
      assert Oban.Peer in Relay.Platform.Queue.Peer.module_info(:attributes)[:behaviour]
    end

    test "T-10: cross-node notifications go through Relay's Valkey notifier" do
      assert @config[:notifier] == Relay.Platform.Queue.Notifier
    end

    test "OP-12: Oban's pruner is not used; Relay's cleaner is" do
      plugins =
        Enum.map(@config[:plugins], fn
          {module, _} -> module
          module -> module
        end)

      assert Pruner in plugins
      refute Oban.Pruner in plugins
      refute Oban.Plugins.Pruner in plugins
      assert @config[:pruner] == nil
    end

    test "T-15: orphaned jobs are rescued after two hours and staging polls every second" do
      assert {Oban.Lifeline, opts} = List.keyfind(@config[:plugins], Oban.Lifeline, 0)
      assert opts[:rescue_after] == 7_200_000
      assert @config[:stager] == [interval: 1_000]
    end

    test "T-3: a node without the worker role runs neither peer nor cleaner" do
      options = Queue.options(@config, [:api])
      assert options[:peer] == false
      assert options[:plugins] == []
    end
  end

  describe "OP-12 cleaner rules" do
    test "OP-12: completed rows go a day after completion, cancelled rows seven days after cancellation" do
      now = ~U[2026-10-16 12:00:00Z]
      {completed, cancelled} = Pruner.cutoffs(now, [])

      assert completed == ~N[2026-10-15 12:00:00.000]
      assert cancelled == ~N[2026-10-09 12:00:00.000]
    end

    test "OP-12: the cleaner validates its options" do
      assert Pruner.validate(interval: 1_000, limit: 10) == :ok
      assert {:error, _} = Pruner.validate(limit: 0)
      assert {:error, _} = Pruner.validate(states: [:discarded])
    end

    test "OP-12: only the queue stores may delete, and only queue rows" do
      allow = Jason.decode!(File.read!("conformance/catalog/sql-allow.json"))
      ephemeral = Enum.join(Relay.Platform.Queue.PrunerStore.ephemeral_tables(), "|")

      for entry <- allow, String.starts_with?(entry["path"], "lib/relay/platform/queue/") do
        assert entry["match"] =~ ~r/\ADELETE FROM relay_queue\.(oban_(jobs|peers)|#{ephemeral})\z/
      end

      source = File.read!("lib/relay/platform/queue/pruner_store.ex")
      assert source =~ "state = 'completed'"
      assert source =~ "state = 'cancelled'"
      refute source =~ "discarded'"
    end
  end
end
