defmodule Relay.Platform.QueueTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Relay.Platform.Queue

  @base [repo: Relay.Repo, prefix: "oban", queues: [default: 1], plugins: [Oban.Plugins.Lifeline]]

  describe "T-14 open-source Oban only" do
    test "T-14: no commercial queue package is a dependency" do
      lock = Mix.Dep.Lock.read()
      refute Enum.any?(Map.keys(lock), &(&1 in [:oban_pro, :oban_web_pro]))
      assert {:hex, :oban, "2.24.1", _, _, _, _, _} = lock[:oban]
    end
  end

  describe "T-17 queue operation" do
    test "T-17: Oban tables live in their own schema" do
      config = Application.fetch_env!(:relay, Oban)
      assert config[:prefix] == "oban"
      refute config[:prefix] == "public"
    end

    test "T-17: the queue schema migration pins its version" do
      [migration] = Path.wildcard("priv/repo/migrations/*_add_oban_jobs.exs")
      source = File.read!(migration)
      assert source =~ ~s/Oban.Migrations.up(version: 14, prefix: "oban")/
      refute source =~ "def down"
    end

    test "T-17: a switch to polling raises an alarm" do
      log =
        capture_log(fn ->
          Queue.handle_event([:oban, :notifier, :switch], %{}, %{status: :isolated}, nil)
          Queue.handle_event([:oban, :stager, :switch], %{}, %{mode: :local}, nil)
        end)

      assert log =~ "notifier isolated"
      assert log =~ "local polling"
    end

    test "T-17: the alarm handler is attached at startup" do
      handlers = :telemetry.list_handlers([:oban, :notifier, :switch])
      assert Enum.any?(handlers, &(&1.id == "relay-queue-alarm"))
    end
  end

  describe "T-3 T-12 roles" do
    test "T-12: a worker node runs queues, plugins and database leadership" do
      assert Queue.options(@base, [:worker]) == @base
      assert Queue.options(@base, [:api, :worker, :socket]) == @base
    end

    test "T-3: a node without the worker role only inserts jobs" do
      options = Queue.options(@base, [:api, :socket])
      assert options[:queues] == []
      assert options[:plugins] == []
      assert options[:peer] == false
      assert options[:prefix] == "oban"
    end

    test "T-12: leadership is database based, never :global" do
      config = Application.fetch_env!(:relay, Oban)
      assert config[:peer] == Oban.Peers.Database
    end
  end

  describe "T-61 testing mode" do
    test "T-61: tests run the queue in manual testing mode with queues off" do
      config = Application.fetch_env!(:relay, Oban)
      assert config[:testing] == :manual
      assert Oban.config().queues == []
    end
  end
end
