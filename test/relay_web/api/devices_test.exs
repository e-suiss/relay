defmodule RelayWeb.Api.DevicesTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @grant "urn:ietf:params:oauth:grant-type:token-exchange"
  @subject_type "urn:ietf:params:oauth:token-type:access_token"
  @outbox "SELECT payload FROM relay.outbox_events WHERE event_type = $1 ORDER BY created_at, id"
  @row "SELECT state, disabled_reason, deleted_at, token_ct, token_bidx FROM relay.devices WHERE id = $1"
  @p256dh "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM"
  @auth "tBHItJI5svbpez7KI4CCXg"

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    token = F.token(scope)
    app = FakeAccess.client!(scope, ["read"])
    external_id = subscriber!(token)

    %{tenant: tenant, scope: scope, token: token, app: app, external_id: external_id}
  end

  defp subscriber!(token) do
    external_id = "user-" <> TenantFixture.random()
    F.body(F.request(:post, "/v1/subscribers", token, %{"external_id" => external_id}), 201)
    external_id
  end

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp devices_path(external_id), do: "/v1/subscribers/#{external_id}/devices"

  defp registration(overrides \\ %{}) do
    Map.merge(
      %{
        "platform" => "fcm",
        "token" => "fcm:" <> TenantFixture.random() <> TenantFixture.random(),
        "app" => "com.example.shop",
        "permission" => "granted"
      },
      overrides
    )
  end

  defp register(ctx, external_id, body, status) do
    F.body(F.request(:post, devices_path(external_id), ctx.token, body), status)
  end

  defp list(ctx, external_id),
    do: F.body(F.request(:get, devices_path(external_id), ctx.token), 200)["data"]

  defp internal(external) do
    {:ok, id} = Relay.ExternalId.decode(external, ["dev", "sub"])
    id
  end

  defp sql!(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp row!(scope, device) do
    [row] = sql!(scope, @row, [internal(device)])
    row
  end

  defp events(scope, type), do: for([payload] <- sql!(scope, @outbox, [type]), do: payload)

  defp recipient!(ctx, external_id) do
    {:ok, id} = Relay.Subscribers.locate(ctx.scope, external_id)
    id
  end

  defp advance!(ctx, by),
    do: F.body(F.request(:post, "/v1/virtual_clock/advance", ctx.token, %{"by" => by}), 200)

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

  describe "API-67 TN-33 device registration" do
    test "API-67, TN-33: a token is stored encrypted, found by its keyed digest and never returned",
         ctx do
      body = registration()
      device = register(ctx, ctx.external_id, body, 201)

      assert "dev_" <> _ = device["id"]
      assert "sub_" <> _ = device["subscriber_id"]
      assert device["token_fingerprint"] =~ ~r/\A[0-9a-f]{16}\z/
      assert %{"state" => "active", "disabled_reason" => nil, "deleted_at" => nil} = device
      refute String.contains?(Jason.encode!(device), body["token"])

      [_state, _reason, _deleted, token_ct, bidx] = row!(ctx.scope, device["id"])
      refute String.contains?(token_ct, body["token"])
      assert byte_size(bidx) == 32

      [listed] = list(ctx, ctx.external_id)
      assert listed["id"] == device["id"]
      refute String.contains?(Jason.encode!(listed), body["token"])
    end

    test "API-67: registering the same token again is idempotent and refreshes last_seen_at",
         ctx do
      body = registration(%{"permission" => "not_determined"})
      first = register(ctx, ctx.external_id, body, 201)
      again = register(ctx, ctx.external_id, Map.put(body, "permission", "granted"), 200)

      assert again["id"] == first["id"]
      assert again["permission"] == "granted"
      assert again["token_fingerprint"] == first["token_fingerprint"]
      assert {:ok, a, _} = DateTime.from_iso8601(first["last_seen_at"])
      assert {:ok, b, _} = DateTime.from_iso8601(again["last_seen_at"])
      assert DateTime.compare(b, a) in [:gt, :eq]
      assert [_one] = list(ctx, ctx.external_id)
    end

    test "API-67: a token held by another subscriber is moved and device.reassigned is emitted",
         ctx do
      other = subscriber!(ctx.token)
      body = registration()
      first = register(ctx, ctx.external_id, body, 201)
      moved = register(ctx, other, body, 201)

      refute moved["id"] == first["id"]
      assert moved["token_fingerprint"] == first["token_fingerprint"]
      assert list(ctx, ctx.external_id) == []
      assert [%{"id" => id}] = list(ctx, other)
      assert id == moved["id"]
      assert ["disabled", "reassigned", %DateTime{}, _ct, _bidx] = row!(ctx.scope, first["id"])

      assert [event] = events(ctx.scope, "device.reassigned")
      assert event["device_id"] == Relay.Id.to_string(internal(moved["id"]))
      assert event["device_fingerprint"] == moved["token_fingerprint"]
      assert event["from_recipient_id"] == Relay.Id.to_string(recipient!(ctx, ctx.external_id))
      assert event["to_recipient_id"] == Relay.Id.to_string(recipient!(ctx, other))
      assert events(ctx.scope, "device.unregistered") == []
    end

    test "API-67: an APNs token needs its environment and a Web Push subscription its keys",
         ctx do
      path = devices_path(ctx.external_id)
      apns = registration(%{"platform" => "apns", "token" => String.duplicate("ab", 32)})
      assert code(F.request(:post, path, ctx.token, apns), 422) == "validation_failed"

      device = register(ctx, ctx.external_id, Map.put(apns, "apns_environment", "sandbox"), 201)

      assert device["apns_environment"] == "sandbox"

      fcm = registration(%{"apns_environment" => "production"})
      assert code(F.request(:post, path, ctx.token, fcm), 422) == "validation_failed"

      endpoint = "https://push.example.com/send/" <> TenantFixture.random()
      web = registration(%{"platform" => "web_push", "token" => endpoint})

      assert code(F.request(:post, path, ctx.token, web), 422) == "validation_failed"
      keys = %{"p256dh" => @p256dh, "auth" => @auth}
      subscribed = register(ctx, ctx.external_id, Map.put(web, "keys", keys), 201)
      assert subscribed["platform"] == "web_push"

      plain = registration(%{"platform" => "web_push", "token" => "not-a-url", "keys" => keys})
      assert code(F.request(:post, path, ctx.token, plain), 422) == "validation_failed"
      unknown = Map.put(registration(), "x", 1)
      assert code(F.request(:post, path, ctx.token, unknown), 422) == "unknown_field"
    end

    test "API-67: a registration for an unknown subscriber is subscriber_not_found", ctx do
      conn = F.request(:post, devices_path("nobody-here"), ctx.token, registration())
      assert code(conn, 404) == "subscriber_not_found"
    end
  end

  describe "CH-74 active device limit" do
    test "CH-74: the registration past the limit disables the least recently seen device", ctx do
      max = Relay.Devices.max_active()
      [oldest | _rest] = for _ <- 1..max, do: register(ctx, ctx.external_id, registration(), 201)

      newest = register(ctx, ctx.external_id, registration(), 201)
      ids = Enum.map(list(ctx, ctx.external_id), & &1["id"])

      assert length(ids) == Relay.Devices.max_active()
      assert newest["id"] in ids
      refute oldest["id"] in ids
      assert ["disabled", "device_limit", %DateTime{}, _ct, _bidx] = row!(ctx.scope, oldest["id"])

      assert [event] = events(ctx.scope, "device.unregistered")
      assert event["disabled_reason"] == "device_limit"
      assert event["device_id"] == Relay.Id.to_string(internal(oldest["id"]))
      assert event["device_fingerprint"] == oldest["token_fingerprint"]
    end

    test "CH-74: a tenant may lower the device limit and never raise it", ctx do
      change = %{
        key: "devices.max_active",
        value: 2,
        expected_version: nil,
        record_digest: TenantFixture.digest()
      }

      assert {:ok, _} = Relay.Tenancy.put_setting(ctx.scope, change, TenantFixture.actor())

      [first, _second, _third] =
        for _ <- 1..3, do: register(ctx, ctx.external_id, registration(), 201)

      assert length(list(ctx, ctx.external_id)) == 2
      assert ["disabled", "device_limit", _at, _ct, _bidx] = row!(ctx.scope, first["id"])

      raised = %{change | value: Relay.Devices.max_active() + 1}

      assert {:error, %Relay.Error{code: :invalid_setting}} =
               Relay.Tenancy.put_setting(ctx.scope, raised, TenantFixture.actor())
    end
  end

  describe "INV-14 CH-11 CH-31 token lifecycle" do
    test "INV-14, CH-11: a permanent failure disables the token at once and emits device.unregistered",
         ctx do
      body = registration()
      device = register(ctx, ctx.external_id, body, 201)

      assert {:ok, :disabled} =
               Relay.Devices.disable(ctx.scope, {:token, body["token"]}, :unregistered)

      assert ["disabled", "unregistered", %DateTime{}, _ct, _bidx] = row!(ctx.scope, device["id"])
      assert [event] = events(ctx.scope, "device.unregistered")
      assert event["disabled_reason"] == "unregistered"
      refute String.contains?(Jason.encode!(event), body["token"])

      assert {:ok, :already_disabled} =
               Relay.Devices.disable(ctx.scope, {:device, internal(device["id"])})

      assert length(events(ctx.scope, "device.unregistered")) == 1
      assert {:ok, :not_found} = Relay.Devices.disable(ctx.scope, {:token, "fcm:unknown"})
    end

    test "CH-11: an APNs 410 timestamp older than the last registration leaves the token in place",
         ctx do
      token = String.duplicate("0f", 32)
      apns = %{"platform" => "apns", "token" => token, "apns_environment" => "production"}
      device = register(ctx, ctx.external_id, registration(apns), 201)
      {:ok, registered_at, _} = DateTime.from_iso8601(device["registered_at"])
      ref = {:token, String.upcase(token)}
      older = [failed_at: DateTime.add(registered_at, -3_600, :second)]
      newer = [failed_at: DateTime.add(registered_at, 1, :second)]

      assert {:ok, :reregistered} = Relay.Devices.disable(ctx.scope, ref, :unregistered, older)
      assert ["active", nil, nil, _ct, _bidx] = row!(ctx.scope, device["id"])
      assert {:ok, :disabled} = Relay.Devices.disable(ctx.scope, ref, :unregistered, newer)
    end

    test "CH-31: previous_token disables the device of the token it replaces", ctx do
      old = registration()
      first = register(ctx, ctx.external_id, old, 201)
      fresh = registration(%{"previous_token" => old["token"]})
      second = register(ctx, ctx.external_id, fresh, 201)

      assert [%{"id" => id}] = list(ctx, ctx.external_id)
      assert id == second["id"]
      assert ["disabled", "replaced", _at, _ct, _bidx] = row!(ctx.scope, first["id"])
    end

    test "CH-31, OP-44: the sweep marks stale devices, disables inactive ones and needs a bound",
         ctx do
      device = register(ctx, ctx.external_id, registration(), 201)

      assert {:error, %Relay.Error{}} = Relay.Devices.sweep(ctx.scope, limit: 0)
      assert {:error, %Relay.Error{}} = Relay.Devices.sweep(ctx.scope, limit: 1_000_000)
      assert {:ok, %{staled: 0, disabled: 0}} = Relay.Devices.sweep(ctx.scope)

      advance!(ctx, "P31D")
      assert {:ok, %{staled: 1, disabled: 0, has_more: false}} = Relay.Devices.sweep(ctx.scope)
      assert [%{"state" => "stale"}] = list(ctx, ctx.external_id)

      recipient = recipient!(ctx, ctx.external_id)
      assert {:ok, [_target]} = Relay.Devices.targets(ctx.scope, recipient, :push, :transactional)

      advance!(ctx, "P240D")
      assert Relay.Devices.sweep_due() >= 1
      assert list(ctx, ctx.external_id) == []
      assert ["disabled", "inactive", _at, _ct, _bidx] = row!(ctx.scope, device["id"])
      assert [event] = events(ctx.scope, "device.unregistered")
      assert event["disabled_reason"] == "inactive"
    end

    test "CH-31: registering a stale device again makes it active", ctx do
      body = registration()
      register(ctx, ctx.external_id, body, 201)
      advance!(ctx, "P31D")
      assert {:ok, %{staled: 1}} = Relay.Devices.sweep(ctx.scope)
      assert register(ctx, ctx.external_id, body, 200)["state"] == "active"
    end

    test "OP-44: the database sweep refuses to run without an upper bound", ctx do
      assert_raise Postgrex.Error, ~r/invalid_argument/, fn ->
        Repo.in_scope(ctx.scope, fn _status ->
          Repo.call!("relay_fn.device_sweep", [2_592_000, 23_328_000, nil])
        end)
      end
    end
  end

  describe "CH-28 C-23 permission and preferences" do
    test "CH-28, CH-29: only permitted devices are targets; otherwise the caller skips", ctx do
      recipient = recipient!(ctx, ctx.external_id)

      assert {:skip, :no_device} =
               Relay.Devices.targets(ctx.scope, recipient, :push, :transactional)

      register(ctx, ctx.external_id, registration(%{"permission" => "denied"}), 201)

      assert {:skip, :no_permission} =
               Relay.Devices.targets(ctx.scope, recipient, :push, :transactional)

      provisional = registration(%{"permission" => "provisional"})
      register(ctx, ctx.external_id, provisional, 201)

      assert {:skip, :no_permission} =
               Relay.Devices.targets(ctx.scope, recipient, :push, :security)

      assert {:ok, [target]} = Relay.Devices.targets(ctx.scope, recipient, :push, :marketing)
      assert target.permission == "provisional"
      assert Relay.Redacted.expose(target.token) == provisional["token"]
      refute inspect(target) =~ provisional["token"]
      assert target.fingerprint =~ ~r/\A[0-9a-f]{16}\z/
      assert {:skip, :no_device} = Relay.Devices.targets(ctx.scope, recipient, :web_push, nil)
    end

    test "CH-28: the reachability summary follows the subscriber's devices", ctx do
      path = "/v1/subscribers/#{ctx.external_id}"
      channels = fn -> F.body(F.request(:get, path, ctx.token), 200)["channels"] end

      assert channels.()["push"] == %{"reachable" => false, "reason" => "no_active_device"}
      register(ctx, ctx.external_id, registration(%{"permission" => "denied"}), 201)
      assert channels.()["push"] == %{"reachable" => false, "reason" => "no_permission"}
      register(ctx, ctx.external_id, registration(), 201)
      assert channels.()["push"] == %{"reachable" => true, "reason" => nil}
      assert channels.()["web_push"]["reason"] == "no_active_device"
    end

    test "C-23, CH-31: removing a device is a soft delete that keeps the preferences", ctx do
      prefs = "/v1/subscribers/#{ctx.external_id}/preferences"
      :ok = F.category!(ctx.token, "orders", "transactional")
      write = %{"level" => "channel", "channel" => "push", "value" => "opt_out"}
      F.body(F.request(:patch, prefs, ctx.token, %{"preferences" => [write]}), 200)
      before = F.body(F.request(:get, prefs, ctx.token), 200)

      device = register(ctx, ctx.external_id, registration(), 201)
      path = devices_path(ctx.external_id) <> "/" <> device["id"]
      removed = F.body(F.request(:delete, path, ctx.token), 200)

      assert %{"state" => "disabled", "disabled_reason" => "removed"} = removed
      assert removed["deleted_at"]
      assert F.body(F.request(:delete, path, ctx.token), 200)["disabled_reason"] == "removed"
      assert F.body(F.request(:get, prefs, ctx.token), 200) == before
      assert ["disabled", "removed", _at, _ct, _bidx] = row!(ctx.scope, device["id"])

      other = subscriber!(ctx.token)
      foreign = devices_path(other) <> "/" <> device["id"]
      assert code(F.request(:delete, foreign, ctx.token), 404) == "device_not_found"
    end

    test "API-67: a device is removed by its token whichever subscriber holds it", ctx do
      body = registration()
      device = register(ctx, ctx.external_id, body, 201)
      removal = %{"token" => body["token"]}
      removed = F.body(F.request(:delete, "/v1/devices/by-token", ctx.token, removal), 200)

      assert removed["id"] == device["id"]
      assert removed["disabled_reason"] == "removed"
      missing = %{"token" => "fcm:" <> TenantFixture.random()}
      conn = F.request(:delete, "/v1/devices/by-token", ctx.token, missing)
      assert code(conn, 404) == "device_not_found"
    end

    test "API-67, TN-33: erasing the subscriber disables its devices and clears their digests",
         ctx do
      TenantFixture.retention_periods!()
      device = register(ctx, ctx.external_id, registration(), 201)
      recipient = recipient!(ctx, ctx.external_id)

      assert {:ok, :erased, _cancelled} =
               Relay.Keys.Erasure.erase_subject(
                 ctx.scope,
                 recipient,
                 "dsr-devices",
                 TenantFixture.actor()
               )

      assert ["disabled", "erased", %DateTime{}, _ct, nil] = row!(ctx.scope, device["id"])
    end
  end

  describe "API-46 the subscriber's own devices" do
    test "API-46: the subscriber token registers and removes only its own devices", ctx do
      me = mine!(ctx, "inbox:read devices:write")
      body = registration()
      conn = F.request(:post, "/v1/subscriber/devices", me.token, body)
      device = F.body(conn, 201)

      assert device["subscriber_id"] == me.id
      refute String.contains?(Jason.encode!(device), body["token"])
      again = F.body(F.request(:post, "/v1/subscriber/devices", me.token, body), 200)
      assert again["id"] == device["id"]

      theirs = register(ctx, ctx.external_id, registration(), 201)
      foreign = "/v1/subscriber/devices/" <> theirs["id"]
      assert code(F.request(:delete, foreign, me.token), 404) == "device_not_found"

      path = "/v1/subscriber/devices/" <> device["id"]
      removed = F.body(F.request(:delete, path, me.token), 200)
      assert %{"state" => "disabled", "disabled_reason" => "logout"} = removed

      reader = mine!(ctx, "inbox:read")
      conn = F.request(:post, "/v1/subscriber/devices", reader.token, registration())
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["code"] == "auth_insufficient_scope"
    end
  end
end
