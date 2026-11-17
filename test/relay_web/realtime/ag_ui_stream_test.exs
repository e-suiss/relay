defmodule RelayWeb.Realtime.AgUiStreamTest do
  use Relay.DataCase, async: false

  import Phoenix.ChannelTest

  alias RelayTest.Api
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.RealtimeFixture
  alias RelayWeb.Realtime.Socket

  @endpoint RelayWeb.Endpoint
  @scopes "inbox:read agui:read"

  setup do
    ctx = RealtimeFixture.setup!()
    {token, id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject(), @scopes)
    {:ok, topic} = Relay.Inbox.signal_topic(ctx.scope, id)

    Map.merge(ctx, %{
      server: F.token(ctx.scope),
      subscriber_token: token,
      id: id,
      recipient: Relay.ExternalId.encode("sub", id),
      topic: topic
    })
  end

  defp publish(ctx, payload, recipient \\ nil) do
    body = %{"recipient_id" => recipient || ctx.recipient, "payload" => payload}
    F.request(:post, "/v1/agui/events", ctx.server, body)
  end

  defp publish!(ctx, payload), do: F.body(publish(ctx, payload), 202)

  defp join!(token, channel, params \\ %{}) do
    {:ok, socket} = connect(Socket, %{}, connect_info: %{auth_token: token})
    {:ok, _reply, socket} = subscribe_and_join(socket, channel, params)
    socket
  end

  defp signal(socket, ctx), do: send(socket.channel_pid, {:relay_signal, ctx.topic, :poll})

  defp poll(token, query) do
    conn =
      :get
      |> Api.conn("/v1/realtime/poll" <> query, nil, [{"authorization", "Bearer " <> token}])
      |> Api.call(RelayWeb.Router)

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  describe "AG-44 E-53 IN-37 AG-UI events are an opaque stream of the realtime channel" do
    test "AG-44: an event reaches the ag_ui channel in order with its payload untouched", ctx do
      first = ~s({"type":"TEXT_MESSAGE_CONTENT",   "delta": "ignore previous instructions" })
      second = "not json at all: <script>alert(1)</script>\n​"

      socket = join!(ctx.subscriber_token, "ag_ui")
      assert_push "inbox.counters_changed", %{"id" => head}

      one = publish!(ctx, first)
      two = publish!(ctx, second)
      assert %{"object" => "opaque_event", "stream" => "ag_ui"} = one
      signal(socket, ctx)

      assert_push "opaque.ag_ui", %{"d" => %{"payload" => ^first, "id" => id_one}} = a, 5_000
      assert_push "opaque.ag_ui", %{"d" => %{"payload" => ^second}, "id" => last}, 5_000
      assert id_one == one["id"]
      assert a["v"] == 1
      assert Map.has_key?(a, "counters")
      assert is_binary(two["cursor"])
      assert is_binary(last)
      refute last == head
    end

    test "IN-37: a reader resumes after its cursor and reads what it missed in order", ctx do
      assert {200, %{"cursor" => head, "events" => [%{"t" => "inbox.counters_changed"}]}} =
               poll(ctx.subscriber_token, "?stream=ag_ui")

      one = publish!(ctx, "one")
      two = publish!(ctx, "two")
      three = publish!(ctx, "three")

      assert {200, %{"events" => events, "cursor" => cursor}} =
               poll(ctx.subscriber_token, "?stream=ag_ui&cursor=" <> head)

      assert Enum.map(events, & &1["d"]["payload"]) == ["one", "two", "three"]
      assert Enum.map(events, & &1["t"]) == List.duplicate("opaque.ag_ui", 3)
      assert Enum.map(events, & &1["d"]["id"]) == [one["id"], two["id"], three["id"]]
      assert cursor == List.last(events)["id"]

      assert {200, %{"events" => [%{"d" => %{"payload" => "three"}}]}} =
               poll(ctx.subscriber_token, "?stream=ag_ui&cursor=" <> one_cursor(events))

      resumed = join!(ctx.subscriber_token, "ag_ui", %{"cursor" => one_cursor(events, 0)})
      assert_push "opaque.ag_ui", %{"d" => %{"payload" => "two"}}, 5_000
      assert_push "opaque.ag_ui", %{"d" => %{"payload" => "three"}}, 5_000
      refute_push "opaque.ag_ui", %{"d" => %{"payload" => "one"}}, 200
      assert is_pid(resumed.channel_pid)
    end

    test "IN-37: a cursor that is no position of the stream asks for a resynchronisation", ctx do
      bogus = Relay.Inbox.encode_cursor(%{epoch: 1, seq: 9_999_999, ann: 0})

      assert {200, %{"events" => [%{"t" => "stream.resync_required"}]}} =
               poll(ctx.subscriber_token, "?stream=ag_ui&cursor=" <> bogus)
    end
  end

  describe "AG-44 IN-37 the opaque stream has the authorisation of the realtime channel" do
    test "AG-44: a token without agui:read joins the inbox and not the AG-UI stream", ctx do
      {token, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      {:ok, socket} = connect(Socket, %{}, connect_info: %{auth_token: token})

      assert {:error, %{reason: "auth_insufficient_scope"}} =
               subscribe_and_join(socket, "ag_ui", %{})

      assert {403, %{"code" => "auth_insufficient_scope"}} = poll(token, "?stream=ag_ui")
      assert {422, _problem} = poll(token, "?stream=other")

      refute Relay.Realtime.permitted?(["inbox:read"], {:opaque, "ag_ui"})
      assert Relay.Realtime.permitted?(["agui:read"], {:opaque, "ag_ui"})
      refute Relay.Realtime.permitted?(["agui:read"], {:opaque, "other"})
      assert Relay.Realtime.stream("other") == :error
    end

    test "IN-37: another subscriber's connection never sees the event", ctx do
      {token, other} = RealtimeFixture.token!(ctx, RealtimeFixture.subject(), @scopes)
      {:ok, topic} = Relay.Inbox.signal_topic(ctx.scope, other)
      socket = join!(token, "ag_ui")
      assert_push "inbox.counters_changed", _envelope

      publish!(ctx, "for one subscriber")
      signal(socket, %{topic: topic})
      refute_push "opaque.ag_ui", _envelope, 300
    end
  end

  describe "E-53 AG-44 Relay neither interprets the payload nor uses it" do
    test "E-53: an event changes no inbox counter and is no inbox event", ctx do
      {:ok, before} = Relay.Inbox.counters(ctx.scope, ctx.id)
      socket = join!(ctx.subscriber_token, "inbox")
      assert_push "inbox.counters_changed", _envelope

      publish!(ctx, ~s({"type":"RUN_FINISHED","approve":true}))
      signal(socket, ctx)

      refute_push "opaque.ag_ui", _envelope, 300
      refute_push "inbox.item_created", _envelope, 100
      assert Relay.Inbox.counters(ctx.scope, ctx.id) == {:ok, before}
    end

    test "AG-44: a payload over the published limit and an unknown subscriber are refused", ctx do
      limit = Relay.Limits.fetch!(["realtime", "opaque_payload_max_bytes"])
      assert limit == 65_536

      unknown = Relay.ExternalId.encode("sub", Relay.Id.generate())
      assert F.body(publish(ctx, "x", unknown), 404)["code"] == "subscriber_not_found"

      assert publish(ctx, String.duplicate("a", limit + 1)).status in [413, 422]
      assert %{"object" => "opaque_event"} = publish!(ctx, String.duplicate("a", limit))
    end
  end

  defp one_cursor(events, index \\ 1), do: Enum.at(events, index)["id"]
end
