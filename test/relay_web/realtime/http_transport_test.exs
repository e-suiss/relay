defmodule RelayWeb.Realtime.HttpTransportTest do
  use Relay.DataCase, async: false

  alias Relay.Operators.SubscriberSuspension
  alias RelayTest.Api
  alias RelayTest.RealtimeFixture
  alias RelayTest.RealtimeSource
  alias RelayTest.TenantFixture

  setup do
    :ok = RealtimeSource.install!()
    RealtimeFixture.setup!()
  end

  defp request(path, token, headers \\ []) do
    auth = if token, do: [{"authorization", "Bearer " <> token}], else: []

    :get
    |> Api.conn(path, nil, auth ++ headers)
    |> Api.call(RelayWeb.Router)
  end

  defp item(n), do: %{"item" => %{"id" => "itm_#{n}"}, "state_version" => 1}

  defp await_subscribed(topic, tries \\ 250) do
    if Map.has_key?(Relay.Platform.Signal.Hub.topics(Relay.Platform.Signal.Hub), topic) do
      :ok
    else
      true = tries > 0
      Process.sleep(20)
      await_subscribed(topic, tries - 1)
    end
  end

  defp events(conn) do
    {Plug.Adapters.Test.Conn, %{chunks: chunks}} = conn.adapter

    chunks
    |> String.split("\n\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, ":"))
    |> Enum.map(fn event ->
      event
      |> String.split("\n")
      |> Map.new(fn line ->
        [field, value] = String.split(line, ": ", parts: 2)
        {field, value}
      end)
    end)
  end

  describe "IN-23 SSE transport" do
    test "IN-23, IN-26: SSE carries the envelopes with the cursor as event id from Last-Event-ID",
         ctx do
      {token, id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      RealtimeSource.append(id, "inbox.item_created", item(1))
      feed_topic = RealtimeSource.topic(ctx.scope, id)

      task =
        Task.async(fn -> request("/v1/realtime/events", token, [{"last-event-id", "0"}]) end)

      :ok = await_subscribed(feed_topic)
      RealtimeSource.append(id, "inbox.item_updated", %{"item_id" => "itm_1"})
      send(task.pid, {:relay_signal, feed_topic, {:seq, 2}})

      {:ok, _view} = SubscriberSuspension.suspend(ctx.scope, id, "abuse", TenantFixture.actor())
      {:ok, suspension_topic} = SubscriberSuspension.topic(ctx.scope)
      send(task.pid, {:relay_signal, suspension_topic, {:seq, 2}})

      conn = Task.await(task, 10_000)
      assert conn.status == 200
      assert ["text/event-stream" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
      assert [first, second] = events(conn)

      assert %{"id" => "1", "event" => "inbox.item_created"} = first
      assert %{"t" => "inbox.item_created", "id" => "1"} = Jason.decode!(first["data"])
      assert %{"id" => "2", "event" => "inbox.item_updated"} = second
      assert %{"counters" => %{"version" => 2}} = Jason.decode!(second["data"])

      {Plug.Adapters.Test.Conn, %{chunks: body}} = conn.adapter
      refute body =~ Relay.Scope.tenant_text(ctx.scope)
    end

    test "IN-32, E-25: SSE needs a subscriber token with inbox:read and a valid cursor", ctx do
      {token, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      {narrow, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject(), "preferences")

      missing = request("/v1/realtime/events", nil)
      assert missing.status == 401
      Api.assert_contract(missing)

      scoped = request("/v1/realtime/events", narrow)
      assert scoped.status == 403
      Api.assert_contract(scoped)
      assert Jason.decode!(scoped.resp_body)["code"] == "auth_insufficient_scope"

      malformed = request("/v1/realtime/events", token, [{"last-event-id", "a b"}])
      assert malformed.status == 422
      Api.assert_contract(malformed)

      device = request("/v1/realtime/events?device_id=a:b", token)
      assert device.status == 422
      Api.assert_contract(device)
    end
  end

  describe "IN-23 long-poll transport" do
    test "IN-23: without a cursor the poll answers the counters and the head at once", ctx do
      {token, id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      RealtimeSource.append(id, "inbox.item_created", item(1))

      conn = request("/v1/realtime/poll", token)
      assert conn.status == 200
      Api.assert_contract(conn)

      assert %{"cursor" => "1", "events" => [%{"t" => "inbox.counters_changed", "id" => "1"}]} =
               Jason.decode!(conn.resp_body)
    end

    test "IN-23, IN-22: a cursor behind the head answers the changes after it", ctx do
      {token, id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      for n <- 1..3, do: RealtimeSource.append(id, "inbox.item_created", item(n))

      conn = request("/v1/realtime/poll?cursor=1", token)
      assert conn.status == 200
      Api.assert_contract(conn)
      body = Jason.decode!(conn.resp_body)

      assert body["cursor"] == "3"
      assert [%{"id" => "2"}, %{"id" => "3"}] = body["events"]
    end

    test "IN-24: a poll at the head waits for the next signal and reads the change", ctx do
      {token, id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      RealtimeSource.append(id, "inbox.item_created", item(1))
      feed_topic = RealtimeSource.topic(ctx.scope, id)

      task = Task.async(fn -> request("/v1/realtime/poll?cursor=1", token) end)
      :ok = await_subscribed(feed_topic)
      RealtimeSource.append(id, "inbox.item_updated", %{"item_id" => "itm_1"})
      send(task.pid, {:relay_signal, feed_topic, {:seq, 2}})

      conn = Task.await(task, 10_000)
      assert conn.status == 200
      Api.assert_contract(conn)

      assert %{"cursor" => "2", "events" => [%{"t" => "inbox.item_updated", "id" => "2"}]} =
               Jason.decode!(conn.resp_body)
    end

    test "IN-22: a malformed cursor is refused", ctx do
      {token, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      conn = request("/v1/realtime/poll?cursor=a%20b", token)
      assert conn.status == 422
      Api.assert_contract(conn)
    end
  end
end
