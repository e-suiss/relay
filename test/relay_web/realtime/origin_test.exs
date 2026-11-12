defmodule RelayWeb.Realtime.OriginTest do
  use Relay.DataCase, async: false

  import Phoenix.ChannelTest

  alias Relay.Operators.SubscriberSuspension
  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.RealtimeFixture
  alias RelayTest.RealtimeSource
  alias RelayTest.TenantFixture
  alias RelayWeb.Realtime.Socket

  @endpoint RelayWeb.Endpoint
  @app "https://app.example.com"

  setup do
    :ok = RealtimeSource.install!()
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    app = FakeAccess.client!(tenant.test, ["read"])

    %{
      tenant: tenant,
      scope: tenant.test,
      access_tenant: tenant.attrs.access_tenant_id,
      app: app,
      token: F.token(tenant.test)
    }
  end

  defp put_origins(ctx, origins, scope \\ nil) do
    token = if scope, do: F.token(scope), else: ctx.token
    F.request(:put, "/v1/realtime_origins", token, %{"origins" => origins})
  end

  defp sse(token, headers) do
    :get
    |> Api.conn("/v1/realtime/events", nil, [{"authorization", "Bearer " <> token} | headers])
    |> Api.call(RelayWeb.Router)
  end

  defp handshake(token, headers) do
    protocol = "phoenix, base64url.bearer.phx." <> Base.encode64(token, padding: false)
    conn = Phoenix.ConnTest.build_conn(:get, "/v1/realtime/websocket?vsn=2.0.0")

    [{"sec-websocket-protocol", protocol} | headers]
    |> Enum.reduce(conn, fn {name, value}, acc -> Plug.Conn.put_req_header(acc, name, value) end)
    |> @endpoint.call(@endpoint.init([]))
  end

  defp code(conn), do: Jason.decode!(conn.resp_body)["code"]

  defp await_subscribed(topic, tries \\ 250) do
    if Map.has_key?(Relay.Platform.Signal.Hub.topics(Relay.Platform.Signal.Hub), topic) do
      :ok
    else
      true = tries > 0
      Process.sleep(20)
      await_subscribed(topic, tries - 1)
    end
  end

  defp await_up(topic, tries \\ 250) do
    case Relay.Platform.Signal.Hub.topics(Relay.Platform.Signal.Hub) do
      %{^topic => :up} ->
        :ok

      _pending when tries > 0 ->
        Process.sleep(20)
        await_up(topic, tries - 1)
    end
  end

  defp suspend_tenant!(ctx) do
    change = %{
      status: "suspended",
      reason: "abuse",
      expected_version: nil,
      record_digest: TenantFixture.digest()
    }

    {:ok, {:changed, _version}} =
      Relay.Tenancy.set_tenant_status(ctx.tenant.live, change, TenantFixture.actor())

    :ok
  end

  describe "IN-54 management API" do
    test "IN-54: the list is read and replaced whole per tenant environment", ctx do
      assert %{"object" => "realtime_origins", "origins" => []} =
               F.body(F.request(:get, "/v1/realtime_origins", ctx.token), 200)

      origins = [@app, "http://localhost:3000"]
      assert %{"origins" => ^origins} = F.body(put_origins(ctx, origins), 200)

      assert %{"origins" => ^origins} =
               F.body(F.request(:get, "/v1/realtime_origins", ctx.token), 200)

      live = F.token(ctx.tenant.live)
      assert %{"origins" => []} = F.body(F.request(:get, "/v1/realtime_origins", live), 200)

      assert %{"origins" => []} = F.body(put_origins(ctx, []), 200)
      assert {:ok, %{realtime_origins: []}} = Relay.Api.Tenant.edge(ctx.scope)
    end

    test "IN-54: an origin that breaks a rule is a field error, never stored", ctx do
      refused = F.body(put_origins(ctx, ["http://localhost:3000"], ctx.tenant.live), 422)
      assert [%{"pointer" => "/origins/0", "code" => "invalid_format"}] = refused["errors"]

      refused = F.body(put_origins(ctx, [@app, @app, "https://*.example.com"]), 422)
      codes = Enum.map(refused["errors"], &{&1["pointer"], &1["code"]})
      assert codes == [{"/origins/1", "conflict"}, {"/origins/2", "invalid_format"}]

      many = for n <- 1..21, do: "https://app#{n}.example.com"
      refused = F.body(put_origins(ctx, many), 422)
      assert %{"pointer" => "/origins", "code" => "too_long"} in refused["errors"]

      assert %{"origins" => []} = F.body(F.request(:get, "/v1/realtime_origins", ctx.token), 200)
    end
  end

  describe "IN-54 origin check on connect" do
    test "IN-54: a WebSocket handshake from an origin not on the list is refused with 403", ctx do
      {token, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())

      refused = handshake(token, [{"origin", @app}])
      assert refused.status == 403
      assert code(refused) == "realtime_origin_not_allowed"

      F.body(put_origins(ctx, [@app]), 200)

      evil = handshake(token, [{"origin", "https://evil.example.com"}])
      assert evil.status == 403
      assert code(evil) == "realtime_origin_not_allowed"

      assert handshake(token, [{"origin", "null"}]).status == 403
      refute handshake(token, [{"origin", @app}]).status == 403
      refute handshake(token, []).status == 403
    end

    test "IN-54: the channel socket checks the origin after the token", ctx do
      {token, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      F.body(put_origins(ctx, [@app]), 200)

      assert {:error, %Relay.Error{code: :realtime_origin_not_allowed}} =
               connect(Socket, %{}, connect_info: %{auth_token: token, origin: "https://x.io"})

      assert {:error, %Relay.Error{code: :auth_invalid_token}} =
               connect(Socket, %{}, connect_info: %{auth_token: "a.b.c", origin: "https://x.io"})

      assert {:ok, _socket} =
               connect(Socket, %{}, connect_info: %{auth_token: token, origin: @app})
      assert {:ok, _socket} = connect(Socket, %{}, connect_info: %{auth_token: token})
    end

    test "IN-54: SSE from an origin not on the list is 403; without Origin it is not affected",
         ctx do
      {token, id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())

      refused = sse(token, [{"origin", "https://evil.example.com"}])
      assert refused.status == 403
      Api.assert_contract(refused)
      assert code(refused) == "realtime_origin_not_allowed"

      F.body(put_origins(ctx, [@app]), 200)
      {:ok, suspension} = SubscriberSuspension.topic(ctx.scope)
      task = Task.async(fn -> sse(token, [{"origin", @app}]) end)
      :ok = await_subscribed(suspension)

      {:ok, _view} = SubscriberSuspension.suspend(ctx.scope, id, "abuse", TenantFixture.actor())
      send(task.pid, {:relay_signal, suspension, {:seq, 2}})

      assert Task.await(task, 10_000).status == 200
    end

    test "IN-54, IN-33: an open connection whose origin leaves the list closes at its next check",
         ctx do
      {token, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      F.body(put_origins(ctx, [@app, "https://other.example.com"]), 200)

      {:ok, socket} = connect(Socket, %{}, connect_info: %{auth_token: token, origin: @app})
      {:ok, _reply, socket} = subscribe_and_join(socket, "inbox", %{})
      {:ok, status} = Relay.Tenancy.status_topic(ctx.scope)

      send(socket.channel_pid, {:relay_signal, status, {:seq, 1}})
      refute_receive {:relay_realtime_close, _code, _reason}, 200

      F.body(put_origins(ctx, ["https://other.example.com"]), 200)
      send(socket.channel_pid, {:relay_signal, status, {:seq, 2}})
      assert_receive {:relay_realtime_close, 1008, "realtime_origin_not_allowed"}, 1_000
    end
  end

  describe "IN-33 TN-10 tenant suspension" do
    test "IN-33, TN-10: suspending the tenant closes its open WebSocket connections at once",
         ctx do
      Process.flag(:trap_exit, true)
      {token, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      {:ok, socket} = connect(Socket, %{}, connect_info: %{auth_token: token})
      {:ok, _reply, socket} = subscribe_and_join(socket, "inbox", %{})
      ref = Process.monitor(socket.channel_pid)
      {:ok, topic} = Relay.Tenancy.status_topic(ctx.scope)
      :ok = await_up(topic)

      :ok = suspend_tenant!(ctx)

      assert_receive {:relay_realtime_close, 1008, "auth_tenant_suspended"}, 5_000
      assert_receive {:DOWN, ^ref, :process, _pid, {:shutdown, :closed}}, 1_000

      assert {:error, %Relay.Error{code: :auth_tenant_suspended}} =
               connect(Socket, %{}, connect_info: %{auth_token: token})
    end

    test "IN-33: the tenant status signal closes an open SSE stream", ctx do
      {token, _id} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      {:ok, topic} = Relay.Tenancy.status_topic(ctx.scope)
      task = Task.async(fn -> sse(token, []) end)
      :ok = await_subscribed(topic)

      :ok = suspend_tenant!(ctx)
      send(task.pid, {:relay_signal, topic, {:seq, 2}})

      assert Task.await(task, 10_000).status == 200
    end

    test "IN-33: a realtime connection listens on the tenant status topic of its environment",
         ctx do
      {:ok, test_topic} = Relay.Tenancy.status_topic(ctx.tenant.test)
      {:ok, live_topic} = Relay.Tenancy.status_topic(ctx.tenant.live)

      assert test_topic in RelayWeb.Realtime.Authorization.topics(ctx.tenant.test)
      assert live_topic in RelayWeb.Realtime.Authorization.topics(ctx.tenant.live)
      refute live_topic in RelayWeb.Realtime.Authorization.topics(ctx.tenant.test)
    end
  end
end
