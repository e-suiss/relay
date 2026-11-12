defmodule RelayWeb.Realtime.InboxStreamTest do
  use Relay.DataCase, async: false

  import Phoenix.ChannelTest

  alias Relay.Operators.SubscriberSuspension
  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.RealtimeFixture
  alias RelayTest.TenantFixture
  alias RelayWeb.Realtime.Socket

  @endpoint RelayWeb.Endpoint

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    scope = tenant.live
    token = F.token(scope)
    F.workflow!(scope, token, "order-shipped", channels: ["in_app"])
    app = FakeAccess.client!(scope, ["read"])
    ctx = %{scope: scope, access_tenant: tenant.attrs.access_tenant_id, app: app, token: token}
    sub = RealtimeFixture.subject()
    {subscriber_token, id} = RealtimeFixture.token!(ctx, sub)
    {:ok, topic} = Relay.Inbox.signal_topic(scope, id)

    Map.merge(ctx, %{sub: sub, subscriber_token: subscriber_token, id: id, topic: topic})
  end

  defp send!(ctx, workflow \\ "order-shipped") do
    body = %{"workflow" => workflow, "to" => [ctx.sub], "data" => %{"order" => "A-1"}}
    accepted = F.body(F.request(:post, "/v1/events", ctx.token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"

    for delivery <- F.body(F.request(:get, path, ctx.token), 200)["data"] do
      {:ok, delivery_id} = Relay.ExternalId.decode(delivery["id"], ["dlv"])
      delivery_id
    end
  end

  defp deliver!(ctx, delivery_id) do
    id = Relay.Id.to_string(delivery_id)
    args = Map.put(Relay.Scope.to_job_args(ctx.scope), "delivery_id", id)
    Relay.Delivery.Send.perform(%Oban.Job{args: args})
    :ok = Relay.Channels.Live.deliver(ctx.scope, delivery_id, args)
  end

  defp item!(ctx) do
    [delivery_id] = send!(ctx)
    deliver!(ctx, delivery_id)
  end

  defp join!(ctx, params \\ %{}) do
    {:ok, socket} = connect(Socket, %{}, connect_info: %{auth_token: ctx.subscriber_token})
    {:ok, _reply, socket} = subscribe_and_join(socket, "inbox", params)
    socket
  end

  defp signal(pid, ctx), do: send(pid, {:relay_signal, ctx.topic, {:seq, 1}})

  defp head!(ctx) do
    {:ok, cursor} = Relay.Inbox.cursor(ctx.scope, ctx.id)
    cursor
  end

  defp sse(ctx, cursor) do
    headers = [
      {"authorization", "Bearer " <> ctx.subscriber_token},
      {"last-event-id", cursor}
    ]

    :get
    |> Api.conn("/v1/realtime/events?device_id=sse_device", nil, headers)
    |> Api.call(RelayWeb.Router)
  end

  defp await_connected(ctx, tries \\ 250) do
    if Relay.Realtime.connected?(ctx.scope, ctx.id, "sse_device") do
      :ok
    else
      true = tries > 0
      Process.sleep(20)
      await_connected(ctx, tries - 1)
    end
  end

  defp close_sse!(ctx, task) do
    {:ok, topic} = SubscriberSuspension.topic(ctx.scope)
    :ok = await_connected(ctx)
    {:ok, _view} = SubscriberSuspension.suspend(ctx.scope, ctx.id, "abuse", TenantFixture.actor())
    send(task.pid, {:relay_signal, topic, {:seq, 1}})
    Task.await(task, 10_000)
  end

  defp events(conn) do
    {Plug.Adapters.Test.Conn, %{chunks: chunks}} = conn.adapter

    chunks
    |> String.split("\n\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, ":"))
    |> Enum.map(fn event ->
      fields =
        event
        |> String.split("\n")
        |> Map.new(fn line ->
          [field, value] = String.split(line, ": ", parts: 2)
          {field, value}
        end)

      Map.put(fields, "data", Jason.decode!(fields["data"]))
    end)
  end

  describe "IN-22 IN-26 the inbox stream over the real source" do
    test "IN-26, IN-2: a delivered in-app item reaches the WebSocket channel with its counters",
         ctx do
      socket = join!(ctx)
      assert_push "inbox.counters_changed", opened
      assert %{"unseen" => 0, "unread" => 0, "total" => 0} = opened["counters"]

      :ok = item!(ctx)
      signal(socket.channel_pid, ctx)

      assert_push "inbox.item_created", created, 5_000
      assert %{"t" => "inbox.item_created", "v" => 1, "id" => created_id} = created
      assert %{"item" => %{"id" => "inb_" <> _, "title" => "Sipariş"}} = created["d"]
      assert created["d"]["state_version"] == 1
      assert %{"unseen" => 1, "unread" => 1, "total" => 1} = created["counters"]
      assert is_binary(created_id)

      assert_push "inbox.counters_changed", counters
      assert counters["d"] == counters["counters"]
      assert counters["counters"]["unread"] == 1
      refute inspect(created) =~ Relay.Scope.tenant_text(ctx.scope)
    end

    test "IN-12, IN-26: an intent reaches the channel as item_updated and counters_changed",
         ctx do
      :ok = item!(ctx)
      socket = join!(ctx)
      assert_push "inbox.counters_changed", %{"counters" => %{"unread" => 1}}

      {:ok, %{items: [item]}} = Relay.Inbox.snapshot(ctx.scope, ctx.id)
      path = "/v1/subscriber/inbox/items/#{item["id"]}/intents"
      F.body(F.request(:post, path, ctx.subscriber_token, %{"op" => "read"}), 200)
      signal(socket.channel_pid, ctx)

      assert_push "inbox.item_updated", updated, 5_000
      assert %{"item_id" => item_id, "state_version" => 2, "changes" => changes} = updated["d"]
      assert item_id == item["id"]
      assert %{"read" => true, "seen" => true} = changes
      assert %{"unseen" => 0, "unread" => 0, "total" => 1} = updated["counters"]

      assert_push "inbox.counters_changed", counters
      assert %{"unread" => 0, "version" => version} = counters["d"]
      assert version == updated["counters"]["version"]
    end

    test "IN-23, IN-26: the SSE stream carries the same item from Last-Event-ID", ctx do
      cursor = head!(ctx)
      :ok = item!(ctx)

      conn = close_sse!(ctx, Task.async(fn -> sse(ctx, cursor) end))
      assert conn.status == 200
      assert [created, counters] = events(conn)

      assert %{"event" => "inbox.item_created", "id" => created_id} = created
      assert created["data"]["id"] == created_id
      assert %{"item" => %{"id" => "inb_" <> _}} = created["data"]["d"]
      assert %{"unread" => 1, "total" => 1} = created["data"]["counters"]

      assert %{"event" => "inbox.counters_changed", "id" => last} = counters
      assert last == head!(ctx)
    end

    test "IN-22, IN-28: a reconnect with the last cursor resumes without loss", ctx do
      :ok = item!(ctx)
      first = join!(ctx, %{"cursor" => head!(ctx)})
      assert_push "inbox.counters_changed", %{"id" => seen}

      Process.unlink(first.channel_pid)
      ref = Process.monitor(first.channel_pid)
      leave(first)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000

      :ok = item!(ctx)
      :ok = item!(ctx)
      _again = join!(ctx, %{"cursor" => seen})

      assert_push "inbox.item_created", %{"id" => second, "d" => %{"item" => a}}
      assert_push "inbox.item_created", %{"id" => third, "d" => %{"item" => b}}
      assert_push "inbox.counters_changed", %{"id" => head, "counters" => %{"total" => 3}}
      refute_push "stream.resync_required", _envelope, 100

      assert a["id"] != b["id"]
      assert [seen, second, third] |> Enum.uniq() |> length() == 3
      assert head == head!(ctx)
    end

    test "IN-29, IN-22: a cursor of an earlier epoch resynchronises from the head", ctx do
      :ok = item!(ctx)
      cursor = head!(ctx)

      {:ok, {_code, box, _key}} = Relay.Inbox.ensure_mailbox(ctx.scope, :subscriber, ctx.id)
      digest = TenantFixture.digest()
      actor = TenantFixture.actor()
      {:ok, {:bumped, _}} = Relay.Inbox.bump_epoch(ctx.scope, box, "restore", digest, actor)

      _socket = join!(ctx, %{"cursor" => cursor})
      assert_push "stream.resync_required", envelope, 5_000
      assert %{"d" => %{"reason" => "epoch_changed"}, "id" => head} = envelope
      assert head == head!(ctx)
      assert head != cursor
      assert envelope["counters"]["total"] == 1
      refute_push "inbox.item_created", _envelope, 200
    end
  end
end
