defmodule Relay.Platform.Queue.NotifierTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mox

  alias Relay.Platform.Queue.Notifier
  alias Relay.ValkeyMock

  setup :verify_on_exit!

  @oban Relay.Platform.Queue.NotifierTest.Oban

  setup do
    conf =
      Oban.Config.new(
        name: @oban,
        repo: Relay.Repo,
        prefix: "relay_queue",
        testing: :manual,
        notifier: {Notifier, adapter: ValkeyMock}
      )

    test = self()
    allow(ValkeyMock, test, fn -> Oban.Registry.whereis(@oban, Oban.Notifier) end)

    stub(ValkeyMock, :subscribe, fn channel ->
      send(test, {:valkey_subscribe, channel})
      :ok
    end)

    stub(ValkeyMock, :unsubscribe, fn channel ->
      send(test, {:valkey_unsubscribe, channel})
      :ok
    end)

    pid =
      start_supervised!(%{
        id: Notifier,
        start:
          {Notifier, :start_link,
           [[conf: conf, adapter: ValkeyMock, name: Oban.Registry.via(@oban, Oban.Notifier)]]}
      })

    %{conf: conf, pid: pid}
  end

  describe "T-55 Oban notifier over Valkey pub/sub" do
    test "T-55: the notifier implements Oban's notifier behaviour" do
      behaviours = Notifier.module_info(:attributes) |> Keyword.get_values(:behaviour)
      assert [Oban.Notifier] in behaviours
    end

    test "T-55: listening subscribes each Oban channel to its own system channel", %{conf: conf} do
      :ok = Oban.Notifier.listen(conf, [:gossip, :signal])
      assert_received {:valkey_subscribe, "relay:s:oban:relay_queue:gossip"}
      assert_received {:valkey_subscribe, "relay:s:oban:relay_queue:signal"}

      :ok = Oban.Notifier.listen(conf, [:gossip])
      refute_received {:valkey_subscribe, _}
    end

    test "T-55: a published notification reaches Valkey as Oban's encoded payload", %{conf: conf} do
      expect(ValkeyMock, :pipeline, fn [["PUBLISH", "relay:s:oban:relay_queue:gossip", payload]] ->
        assert Jason.decode!(payload) == %{"hello" => "world"}
        {:ok, [1]}
      end)

      assert :ok = Oban.Notifier.notify(conf, :gossip, %{hello: "world"})
    end

    test "T-55: a message from Valkey is relayed to the local listeners", %{conf: conf, pid: pid} do
      :ok = Oban.Notifier.listen(conf, [:gossip])
      send(pid, {:valkey, :message, "relay:s:oban:relay_queue:gossip", ~s({"n":1})})
      assert_receive {:notification, :gossip, %{"n" => 1}}
    end

    test "T-55: messages on unknown channels and undecodable payloads are dropped", %{
      conf: conf,
      pid: pid
    } do
      :ok = Oban.Notifier.listen(conf, [:gossip])

      log =
        capture_log(fn ->
          send(pid, {:valkey, :message, "relay:s:oban:relay_queue:other", ~s({"n":1})})
          send(pid, {:valkey, :message, "relay:s:oban:relay_queue:gossip", "not json"})
          send(pid, {:valkey, :message, "relay:s:oban:relay_queue:gossip", ~s({"n":2})})
          assert_receive {:notification, :gossip, %{"n" => 2}}
        end)

      refute_received {:notification, :gossip, %{"n" => 1}}
      assert log =~ "undecodable"
      assert Process.alive?(pid)
    end

    test "T-55: unlisten drops the Valkey subscription once no listener is left", %{conf: conf} do
      :ok = Oban.Notifier.listen(conf, [:gossip])
      :ok = Oban.Notifier.unlisten(conf, [:gossip])
      assert_received {:valkey_unsubscribe, "relay:s:oban:relay_queue:gossip"}
    end

    test "T-55: a restarted notifier listens again on every registered channel", %{
      conf: conf,
      pid: pid
    } do
      :ok = Oban.Notifier.listen(conf, [:gossip])
      assert_received {:valkey_subscribe, "relay:s:oban:relay_queue:gossip"}

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert_receive {:valkey_subscribe, "relay:s:oban:relay_queue:gossip"}, 1_000
    end
  end

  describe "T-55 Valkey outage and reconnect" do
    test "T-55: while Valkey is down notify fails fast so Oban stages locally by polling", %{
      conf: conf
    } do
      expect(ValkeyMock, :pipeline, fn _ -> {:error, %Redix.ConnectionError{reason: :closed}} end)
      assert {:error, %RuntimeError{}} = Oban.Notifier.notify(conf, :insert, %{queue: "default"})
    end

    test "T-17: losing the connection is logged and reported, and reconnecting resumes relaying",
         %{conf: conf, pid: pid} do
      :ok = Oban.Notifier.listen(conf, [:gossip])
      handler = "notifier-down-#{inspect(self())}"
      test = self()

      :telemetry.attach(
        handler,
        [:relay, :queue, :notifier, :down],
        fn _event, _measure, _meta, _ -> send(test, :notifier_down) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      send(pid, {:valkey, :up, "relay:s:oban:relay_queue:gossip"})

      log =
        capture_log(fn ->
          send(pid, {:valkey, :down})
          assert_receive :notifier_down
        end)

      assert log =~ "polls"

      send(pid, {:valkey, :up, "relay:s:oban:relay_queue:gossip"})
      send(pid, {:valkey, :message, "relay:s:oban:relay_queue:gossip", ~s({"after":"reconnect"})})
      assert_receive {:notification, :gossip, %{"after" => "reconnect"}}
    end
  end

  describe "T-10 T-13 no database or distribution notifier" do
    test "T-10: the configured notifier is Relay's Valkey notifier, never LISTEN/NOTIFY or :pg" do
      config = Application.fetch_env!(:relay, Oban)
      assert config[:notifier] == Notifier
      refute config[:notifier] in [Oban.Notifiers.Postgres, Oban.Notifiers.PG]
    end
  end
end
