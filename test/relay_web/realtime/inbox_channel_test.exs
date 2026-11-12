defmodule RelayWeb.Realtime.InboxChannelTest do
  use Relay.DataCase, async: false

  import Phoenix.ChannelTest

  alias Relay.Operators.SubscriberSuspension
  alias RelayTest.RealtimeFixture
  alias RelayTest.RealtimeSource
  alias RelayTest.TenantFixture
  alias RelayWeb.Realtime.Socket

  @endpoint RelayWeb.Endpoint

  setup do
    :ok = RealtimeSource.install!()
    RealtimeFixture.setup!()
  end

  defp connect!(token, params \\ %{}) do
    {:ok, socket} = connect(Socket, params, connect_info: %{auth_token: token})
    socket
  end

  defp join!(socket, params \\ %{}) do
    {:ok, _reply, socket} = subscribe_and_join(socket, "inbox", params)
    socket
  end

  defp item(n), do: %{"item" => %{"id" => "itm_#{n}", "title" => "t#{n}"}, "state_version" => 1}

  defp session(socket), do: :sys.get_state(socket.channel_pid).assigns.session

  defp await_up(topic, tries \\ 250) do
    case Relay.Platform.Signal.Hub.topics(Relay.Platform.Signal.Hub) do
      %{^topic => :up} ->
        :ok

      _pending when tries > 0 ->
        Process.sleep(20)
        await_up(topic, tries - 1)
    end
  end

  describe "IN-32 IN-33 E-25 server-side subscription" do
    test "IN-32, E-25: only a subscriber token with inbox:read connects; the token decides the stream",
         ctx do
      {token, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      {narrow, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject(), "preferences")

      assert {:error, %Relay.Error{code: :auth_missing_credentials}} =
               connect(Socket, %{}, connect_info: %{})

      assert {:error, %Relay.Error{code: :auth_invalid_token}} =
               connect(Socket, %{}, connect_info: %{auth_token: "a.b.c"})

      assert {:error, %Relay.Error{code: :auth_insufficient_scope}} =
               connect(Socket, %{}, connect_info: %{auth_token: narrow})

      assert {:error, %Relay.Error{code: :validation_failed}} =
               connect(Socket, %{"device_id" => "-x:"}, connect_info: %{auth_token: token})

      assert {:ok, _socket} = connect(Socket, %{}, connect_info: %{auth_token: token})
    end

    test "IN-32: inbox is the only topic; it names neither tenant nor subscriber", ctx do
      {token, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      _socket = connect!(token)

      assert {RelayWeb.Realtime.InboxChannel, _opts} = Socket.__channel__("inbox")
      assert Socket.__channel__("inbox:" <> Relay.Scope.tenant_text(ctx.scope)) == nil
      assert Socket.__channel__("stream:agui") == nil
    end
  end

  describe "IN-26 IN-24 INV-53 envelope and signal" do
    test "IN-26: a join without a cursor starts at the head with the counters", ctx do
      {token, id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      RealtimeSource.append(id, "inbox.item_created", item(1))
      _socket = token |> connect!() |> join!()

      assert_push "inbox.counters_changed", envelope
      assert %{"t" => "inbox.counters_changed", "v" => 1, "id" => "1"} = envelope
      assert envelope["d"] == envelope["counters"]
      assert %{"unseen" => 1, "unread" => 0, "total" => 0, "version" => 1} = envelope["counters"]
      assert {:ok, _at, 0} = DateTime.from_iso8601(envelope["ts"])
      refute inspect(envelope) =~ Relay.Scope.tenant_text(ctx.scope)
    end

    test "IN-24, INV-53: a Valkey signal carries only the sequence; the connection reads the change",
         ctx do
      {token, id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      socket = token |> connect!() |> join!()
      assert_push "inbox.counters_changed", %{"id" => "0"}

      seq = RealtimeSource.append(id, "inbox.item_created", item(1))
      :ok = Relay.Platform.publish_signal(RealtimeSource.topic(ctx.scope, id), seq)

      assert_push "inbox.item_created", envelope, 5_000
      assert %{"id" => "1", "d" => %{"item" => %{"id" => "itm_1"}}} = envelope
      assert envelope["d"]["state_version"] == 1
      assert envelope["counters"]["version"] == 1

      send(socket.channel_pid, {:relay_signal, RealtimeSource.topic(ctx.scope, id), :poll})
      refute_push "inbox.item_created", _envelope, 200
    end

    test "IN-22, IN-29: a cursor resumes in order; a failed read keeps the cursor", ctx do
      {token, id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      for n <- 1..3, do: RealtimeSource.append(id, "inbox.item_created", item(n))
      socket = token |> connect!() |> join!(%{"cursor" => "1"})

      assert_push "inbox.item_created", %{"id" => "2", "d" => %{"item" => %{"id" => "itm_2"}}}
      assert_push "inbox.item_created", %{"id" => "3", "d" => %{"item" => %{"id" => "itm_3"}}}

      RealtimeSource.fail(id, :down)
      RealtimeSource.append(id, "inbox.item_updated", %{"item_id" => "itm_1"})
      send(socket.channel_pid, {:relay_signal, RealtimeSource.topic(ctx.scope, id), {:seq, 4}})
      refute_push "inbox.item_updated", _envelope, 200

      RealtimeSource.fail(id, nil)
      send(socket.channel_pid, {:relay_realtime, :retry})
      assert_push "inbox.item_updated", %{"id" => "4"}
    end

    test "IN-29: more than 500 changes since the cursor resynchronise from the head", ctx do
      {token, id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      for n <- 1..501, do: RealtimeSource.append(id, "inbox.item_created", item(n))
      _socket = token |> connect!() |> join!(%{"cursor" => "0"})

      assert_push "stream.resync_required", envelope
      assert %{"d" => %{"reason" => "truncated"}, "id" => "501"} = envelope
      refute_push "inbox.item_created", _envelope, 100
    end

    test "IN-22: an unknown cursor resynchronises; a malformed one is refused", ctx do
      {token, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      _socket = token |> connect!() |> join!(%{"cursor" => "999"})
      assert_push "stream.resync_required", %{"d" => %{"reason" => "cursor_invalid"}, "id" => "0"}

      assert {:error, %{reason: "validation_failed"}} =
               subscribe_and_join(connect!(token), "inbox", %{"cursor" => "a b"})
    end
  end

  describe "IN-31 read-only channel" do
    test "IN-31: every client message is refused; writes go through REST", ctx do
      {token, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      socket = token |> connect!() |> join!()

      for event <- ["inbox.item_created", "mark_read", "subscribe", "history"] do
        ref = push(socket, event, %{"topic" => "inbox", "item_id" => "itm_1"})
        assert_reply ref, :error, %{reason: "read_only"}
      end
    end
  end

  describe "IN-33 INV-42 TN-10 authorization continuity" do
    test "IN-33, TN-10: suspending the subscriber closes its open connection from the server",
         ctx do
      Process.flag(:trap_exit, true)
      {token, id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      socket = token |> connect!() |> join!()
      pid = socket.channel_pid
      ref = Process.monitor(pid)
      {:ok, topic} = SubscriberSuspension.topic(ctx.scope)
      :ok = await_up(topic)

      {:ok, _view} = SubscriberSuspension.suspend(ctx.scope, id, "abuse", TenantFixture.actor())

      assert_receive {:relay_realtime_close, 1008, "auth_subscriber_suspended"}, 5_000
      assert_receive {:DOWN, ^ref, :process, _pid, {:shutdown, :closed}}, 1_000
      assert_receive {:EXIT, ^pid, {:shutdown, :closed}}, 1_000

      assert {:error, %Relay.Error{code: :auth_subscriber_suspended}} =
               connect(Socket, %{}, connect_info: %{auth_token: token})
    end

    test "INV-42: the token's expiry closes the connection unless a fresh token replaced it",
         ctx do
      sub = RealtimeFixture.subject()
      {token, _id} = RealtimeFixture.token!(ctx, sub)
      {fresh, _id} = RealtimeFixture.token!(ctx, sub)
      {other, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      socket = token |> connect!() |> join!()

      stale = session(socket).expiry
      ref = push(socket, "auth.refresh", %{"token" => other})
      assert_reply ref, :error, %{reason: "auth_invalid_token"}

      ref = push(socket, "auth.refresh", %{"token" => fresh})
      assert_reply ref, :ok
      assert session(socket).token == fresh

      send(socket.channel_pid, {:relay_realtime, :expired, stale})
      refute_receive {:relay_realtime_close, _code, _reason}, 100

      send(socket.channel_pid, {:relay_realtime, :expired, session(socket).expiry})
      assert_receive {:relay_realtime_close, 1008, "auth_expired_token"}, 1_000
    end
  end

  describe "IN-52 IN-40 connection set" do
    test "IN-52: more than 10 connections of a subscriber close the oldest", ctx do
      {token, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())

      [oldest | rest] =
        for _n <- 1..11 do
          Process.sleep(2)
          token |> connect!() |> join!()
        end

      send(List.last(rest).channel_pid, {:relay_realtime, :heartbeat})
      refute_receive {:relay_realtime_close, _code, _reason}, 200

      send(oldest.channel_pid, {:relay_realtime, :heartbeat})
      assert_receive {:relay_realtime_close, 1008, "connection_limit"}, 1_000
    end

    test "IN-40: a device with a live connection is connected until it leaves", ctx do
      {token, id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      socket = token |> connect!(%{"device_id" => "dev_a"}) |> join!()

      assert Relay.Realtime.connected?(ctx.scope, id, "dev_a")
      refute Relay.Realtime.connected?(ctx.scope, id, "dev_b")
      refute Relay.Realtime.connected?(ctx.scope, id, "-")

      Process.unlink(socket.channel_pid)
      ref = Process.monitor(socket.channel_pid)
      leave(socket)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000

      refute Relay.Realtime.connected?(ctx.scope, id, "dev_a")
    end
  end
end
