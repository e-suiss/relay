defmodule RelayWeb.Api.DeviceStatusTest do
  use Relay.DataCase, async: false

  alias Relay.Datasets
  alias Relay.Repo
  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @grant "urn:ietf:params:oauth:grant-type:token-exchange"
  @subject_type "urn:ietf:params:oauth:token-type:access_token"
  @all ~w(break focus headphones locked worn)
  @datasets ["channel_event_evidence", "channel_parameters"]
  @status_path "/v1/subscriber/devices/status"
  @decision "SELECT decision, decision_rule_id, deferred_until, timing_released_at
    FROM relay.deliveries WHERE id = $1"

  defmodule Registry do
    @moduledoc false

    def connected?(_scope, _subscriber_id, device_id),
      do: device_id in Application.get_env(:relay, :device_status_test_connected, [])
  end

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    token = F.token(scope)
    app = FakeAccess.client!(scope, ["read"])

    %{tenant: tenant, scope: scope, token: token, app: app}
  end

  defp mine!(ctx, scopes) do
    sub = "pairwise-" <> FakeAccess.random()
    token = FakeAccess.user_token(ctx.tenant.attrs.access_tenant_id, ctx.app, sub)

    form = %{
      "grant_type" => @grant,
      "subject_token" => token,
      "subject_token_type" => @subject_type,
      "scope" => scopes
    }

    headers = FakeAccess.exchange_headers(token)

    conn =
      :post
      |> Api.conn("/v1/subscriber/token", URI.encode_query(form), headers)
      |> Api.call(RelayWeb.Router)

    body = F.body(conn, 200)
    %{token: body["access_token"], id: body["subscriber_id"], external_id: sub}
  end

  defp device!(me) do
    body = %{
      "platform" => "fcm",
      "token" => "fcm:" <> TenantFixture.random() <> TenantFixture.random(),
      "app" => "com.example.shop",
      "permission" => "granted"
    }

    F.body(F.request(:post, "/v1/subscriber/devices", me.token, body), 201)["id"]
  end

  defp status(me, device, body, headers \\ []) do
    F.request(:patch, "/v1/subscriber/devices/#{device}/status", me.token, body, headers)
  end

  defp write(signals, extra \\ %{}),
    do: Map.merge(%{"version" => "v1", "signals" => signals}, extra)

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp internal(external, prefixes) do
    {:ok, id} = Relay.ExternalId.decode(external, prefixes)
    id
  end

  defp sql!(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp event(workflow, to, extra) do
    %{"workflow" => workflow, "to" => [to], "data" => %{"order" => "A-1"}}
    |> Map.merge(extra)
  end

  defp send!(ctx, workflow, to, extra),
    do: F.body(F.request(:post, "/v1/events", ctx.token, event(workflow, to, extra)), 202)

  defp delivery!(ctx, accepted, channel) do
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    data = F.body(F.request(:get, path, ctx.token), 200)["data"]
    Enum.find(data, &(&1["channel"] == channel))
  end

  defp decision(scope, delivery) do
    [row] = sql!(scope, @decision, [internal(delivery["id"], ["dlv"])])
    row
  end

  defp with_env(key, value, fun) do
    previous = Application.get_env(:relay, key)
    Application.put_env(:relay, key, value)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:relay, key, previous),
        else: Application.delete_env(:relay, key)
    end
  end

  defp next_break, do: %{"timing" => "next_break", "max_defer" => "PT2H"}

  describe "IN-47 IN-53 device status channel" do
    test "IN-47, IN-53: a device writes changed signals and its clients read them", ctx do
      me = mine!(ctx, "inbox:read devices:write presence:write")
      device = device!(me)

      written = F.body(status(me, device, write(%{"locked" => true})), 200)
      assert written["device_id"] == device
      assert written["version"] == "v1"
      assert written["signals"]["locked"] == true
      for name <- @all -- ["locked"], do: assert(written["signals"][name] == "unknown")

      reader = mine!(ctx, "inbox:read")
      assert F.body(F.request(:get, @status_path, reader.token), 200)["data"] == []

      listed = F.body(F.request(:get, @status_path, me.token), 200)
      assert [%{"device_id" => ^device, "signals" => %{"locked" => true}}] = listed["data"]
    end

    test "IN-53: a signal or value outside dictionary v1 is unknown_field", ctx do
      me = mine!(ctx, "devices:write presence:write")
      device = device!(me)

      assert code(status(me, device, write(%{"mood" => true})), 422) == "unknown_field"
      assert code(status(me, device, write(%{"locked" => "yes"})), 422) == "unknown_field"
      assert code(status(me, device, write(%{})), 422) == "validation_failed"

      zero = write(%{"focus" => true}, %{"ttl" => "PT0S"})
      assert code(status(me, device, zero), 422) == "validation_failed"

      other = %{"version" => "v2", "signals" => %{"focus" => true}}
      assert code(status(me, device, other), 422) == "validation_failed"
    end

    test "IN-53: the time to live is cut at PT15M and a device writes once a second", ctx do
      me = mine!(ctx, "devices:write presence:write")
      device = device!(me)

      assert F.body(status(me, device, write(%{"focus" => true}, %{"ttl" => "P1D"})), 200)
      conn = status(me, device, write(%{"focus" => false}))
      assert code(conn, 429) == "rate_limited"
      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["1"]
    end

    test "IN-47: presence:write writes only the token holder's own device", ctx do
      me = mine!(ctx, "devices:write presence:write")
      device = device!(me)
      other = mine!(ctx, "devices:write presence:write")
      theirs = device!(other)

      assert code(status(me, theirs, write(%{"break" => true})), 404) == "device_not_found"

      reader = mine!(ctx, "inbox:read devices:write")
      conn = status(reader, device, write(%{"break" => true}))
      assert code(conn, 403) == "auth_insufficient_scope"
    end

    test "IN-47, IN-48: the status never reaches PostgreSQL, not even as a key", ctx do
      me = mine!(ctx, "devices:write presence:write")
      device = device!(me)
      count = "SELECT count(*) FROM relay.idempotency_keys"
      [[before]] = sql!(ctx.scope, count, [])

      key = {"idempotency-key", "presence-" <> TenantFixture.random()}
      assert F.body(status(me, device, write(%{"headphones" => true}), [key]), 200)
      assert sql!(ctx.scope, count, []) == [[before]]
    end
  end

  describe "WF-56 WF-57 next break" do
    test "WF-56: next_break needs max_defer within expires_at, and only it", ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped", channels: ["push"])
      me = mine!(ctx, "devices:write presence:write")
      device!(me)
      later = ctx.scope |> Relay.Clock.business_now() |> DateTime.add(3_600)

      cases = [
        %{"timing" => "next_break"},
        %{"timing" => "next_break", "max_defer" => "P1M"},
        Map.put(next_break(), "expires_at", DateTime.to_iso8601(later)),
        %{"max_defer" => "PT1H"}
      ]

      for extra <- cases do
        body = event("order-shipped", me.external_id, extra)
        problem = F.body(F.request(:post, "/v1/events", ctx.token, body), 422)
        assert problem["code"] == "validation_failed"
        assert Enum.any?(problem["errors"], &(&1["pointer"] == "/max_defer")), inspect(extra)
      end
    end

    test "WF-56, IN-53: a device break transition releases a waiting push", ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped", channels: ["push"])
      me = mine!(ctx, "devices:write presence:write")
      device = device!(me)

      accepted = send!(ctx, "order-shipped", me.external_id, next_break())
      delivery = delivery!(ctx, accepted, "push")
      assert delivery["rule_id"] == "next_break.deferred"
      assert ["defer", "next_break.deferred", until, nil] = decision(ctx.scope, delivery)
      assert DateTime.diff(until, Relay.Clock.business_now(ctx.scope)) in 7_000..7_200
      jobs = length(F.delivery_jobs(delivery["id"]))

      assert F.body(status(me, device, write(%{"focus" => true})), 200)
      assert [_decision, _rule, _until, nil] = decision(ctx.scope, delivery)

      Process.sleep(1_100)
      assert F.body(status(me, device, write(%{"focus" => false})), 200)
      assert [_decision, _rule, _until, %DateTime{}] = decision(ctx.scope, delivery)
      assert length(F.delivery_jobs(delivery["id"])) == jobs + 1

      id = internal(delivery["id"], ["dlv"])
      assert {:send, _info} = Relay.Policy.Live.job(ctx.scope, id)
    end

    test "WF-56, E-77: the security class ignores next_break with timing_ignored", ctx do
      opts = [channels: ["push"], message_class: "security"]
      F.workflow!(ctx.scope, ctx.token, "login-alert", opts)

      me = mine!(ctx, "devices:write presence:write")
      device!(me)

      accepted = send!(ctx, "login-alert", me.external_id, next_break())
      assert Enum.any?(accepted["warnings"] || [], &(&1["code"] == "timing_ignored"))
      refute delivery!(ctx, accepted, "push")["rule_id"] == "next_break.deferred"
    end
  end

  describe "IN-40 no push to a connected device" do
    setup do
      forget = fn ->
        for name <- @datasets do
          key = {Datasets.installation_scope(), name}
          :ok = Datasets.Cache.invalidate(Datasets.Cache, key)
        end
      end

      forget.()
      {:ok, _report} = Datasets.load_package(TenantFixture.actor())
      on_exit(forget)
      :ok
    end

    test "IN-40: a push the realtime connection carries skips a connected device", ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped", channels: ["in_app", "push"])
      me = mine!(ctx, "devices:write presence:write")
      device = internal(device!(me), ["dev"])
      accepted = send!(ctx, "order-shipped", me.external_id, %{})
      push = internal(delivery!(ctx, accepted, "push")["id"], ["dlv"])

      with_env(Relay.Devices, [connections: Registry], fn ->
        with_env(:device_status_test_connected, [device], fn ->
          assert Relay.Channels.Live.deliver(ctx.scope, push, %{}) == :ok
        end)
      end)

      skipped = delivery!(ctx, accepted, "push")
      assert skipped["rule_id"] == "channel.realtime_connected"
    end
  end
end
