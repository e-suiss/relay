defmodule Relay.Devices.SignalsTest do
  use Relay.DataCase, async: false

  alias Relay.Devices.Signals

  defmodule Sender do
    @moduledoc false

    def send_signal(_scope, target, signal) do
      send(Application.fetch_env!(:relay, :signals_test_pid), {:signal, target.id, signal})
      :ok
    end
  end

  defmodule Registry do
    @moduledoc false

    def connected?(_scope, _subscriber_id, device_id),
      do: device_id in Application.get_env(:relay, :signals_test_connected, [])
  end

  setup do
    previous = Application.get_env(:relay, Relay.Devices)
    Application.put_env(:relay, Relay.Devices, signal_sender: Sender, connections: Registry)
    Application.put_env(:relay, :signals_test_pid, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:relay, Relay.Devices, previous),
        else: Application.delete_env(:relay, Relay.Devices)

      Application.delete_env(:relay, :signals_test_pid)
      Application.delete_env(:relay, :signals_test_connected)
    end)

    scope = Relay.Scope.new!(Relay.Id.generate(), :live)
    %{scope: scope, subscriber: Relay.Id.generate()}
  end

  defp target(platform), do: %{id: Relay.Id.generate(), platform: platform}

  defp args(ctx, kind, attrs \\ %{}),
    do: Signals.job_args(ctx.scope, ctx.subscriber, kind, Map.put_new(attrs, :counter_version, 7))

  describe "IN-35 IN-38 IN-52 sync signals" do
    test "IN-38, IN-40: a read reaches every mobile device without a realtime connection", ctx do
      ios = target("apns")
      [android, connected] = [target("fcm"), target("fcm")]
      web = target("web_push")
      Application.put_env(:relay, :signals_test_connected, [connected.id])
      notification = Relay.Id.generate()
      read = args(ctx, :read, %{notification_id: notification})

      outcomes = Signals.run(ctx.scope, ctx.subscriber, [ios, android, connected, web], read)

      assert outcomes == %{ios.id => :sent, android.id => :sent, connected.id => :connected}
      assert_received {:signal, id, %{kind: :read, ttl_s: 60, notification_id: ^notification}}
      assert id == android.id
      assert_received {:signal, id, %{kind: :read, counter_version: 7, ttl_s: nil}}
      assert id == ios.id
      refute_received {:signal, _id, _signal}
    end

    test "IN-38: the device the read came from is left out", ctx do
      [one, other] = [target("fcm"), target("fcm")]
      read = args(ctx, :read, %{notification_id: Relay.Id.generate(), except_device_id: one.id})

      assert Signals.run(ctx.scope, ctx.subscriber, [one, other], read) == %{other.id => :sent}
    end

    test "IN-52: iOS signals coalesce within 60 seconds into one trailing signal", ctx do
      ios = target("apns")
      sync = args(ctx, :sync)

      assert Signals.run(ctx.scope, ctx.subscriber, [ios], sync) == %{ios.id => :sent}
      assert Signals.run(ctx.scope, ctx.subscriber, [ios], sync) == %{ios.id => :trailing}
      assert Signals.run(ctx.scope, ctx.subscriber, [ios], sync) == %{ios.id => :coalesced}

      device = Relay.Id.to_string(ios.id)

      assert [[^device]] =
               RelayTest.IngestFixture.jobs("Relay.Devices.SignalJob", ctx.scope, "device_id")
    end

    test "IN-52: at most three iOS signals an hour reach a device; the rest drop", ctx do
      ios = target("apns")
      path = ["sync_hour", Relay.Id.to_string(ios.id)]

      for member <- ~w(a b c),
          do: {:ok, _count} = Relay.Platform.sliding_set_add(ctx.scope, path, 3_600_000, member)

      outcomes = Signals.run(ctx.scope, ctx.subscriber, [ios], args(ctx, :sync))
      assert outcomes == %{ios.id => :dropped}
      refute_received {:signal, _id, _signal}
    end

    test "IN-35, T-15: the job carries the scope, identifiers and counter version", ctx do
      counters = %{version: 12, unseen: 3}
      assert {:ok, job} = Relay.Devices.sync(ctx.scope, ctx.subscriber, counters)
      keys = job.args |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
      assert keys == ~w(counter_version environment kind subscriber_id tenant_id)
      assert job.args["counter_version"] == 12

      notification = Relay.Id.generate()
      subscriber = ctx.subscriber
      assert {:ok, read} = Relay.Devices.propagate_read(ctx.scope, subscriber, notification, %{})
      assert read.args["notification_id"] == Relay.Id.to_string(notification)
      assert read.args["counter_version"] == nil
    end
  end
end
