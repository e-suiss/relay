defmodule Relay.Channels.PushAdaptersTest do
  use ExUnit.Case, async: false

  alias Relay.Channels.Apns
  alias Relay.Channels.Fcm
  alias Relay.Channels.Hms
  alias Relay.Channels.Push.Jwt
  alias Relay.Channels.Push.WebPush.Encryption
  alias Relay.Channels.UnifiedPush
  alias Relay.Channels.WebPush
  alias RelayTest.H2Server
  alias RelayTest.PushFixture

  @token String.duplicate("ab", 32)
  @apns_settings %{
    "team_id" => "TEAM123456",
    "key_id" => "KEY1234567",
    "key_label" => "apns-team-key",
    "bundle_id" => "com.example.app"
  }
  @href "https://example.com/orders/1"
  @audience "//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/q"

  defp put_config(adapter, config) do
    previous = Application.get_env(:relay, adapter)
    Application.put_env(:relay, adapter, config)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:relay, adapter, previous),
        else: Application.delete_env(:relay, adapter)
    end)
  end

  defp device_target(value, device) do
    %{kind: :device, id: Relay.Id.generate(), value: Relay.Redacted.wrap(value), device: device}
  end

  defp apns_request(fields \\ %{}) do
    device = %{platform: "apns", app: "com.example.app", apns_environment: "production"}

    defaults = %{
      target: device_target(@token, device),
      account: %{"settings" => @apns_settings}
    }

    PushFixture.request("apns", Map.merge(defaults, fields))
  end

  defp apns(response) do
    {:ok, port} = H2Server.start(fn _request -> response end)
    put_config(Apns, origins: %{"production" => {:http, "localhost", port}})
  end

  defp web_request(provider, ctx, fields) do
    device = %{platform: provider, app: "web-app", keys: Relay.Redacted.wrap(ctx.keys)}
    target = device_target("https://push.example/sub/1", device)
    PushFixture.request(provider, Map.merge(%{target: target}, fields))
  end

  defp hms(parent, answer) do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if String.ends_with?(conn.request_path, "/token") do
        Req.Test.json(conn, %{"access_token" => "hms-token", "expires_in" => 3600})
      else
        send(parent, {:hms, conn.request_path, Map.new(conn.req_headers), body})
        Req.Test.json(conn, answer)
      end
    end

    put_config(Hms,
      token_url: "https://oauth.example/oauth2/v3/token",
      send_url: "https://push.example/v1/",
      http: [plug: plug]
    )
  end

  defp hms_request(push) do
    PushFixture.request("hms", %{
      account: %{"settings" => %{"app_id" => "1234", "client_id" => "1234"}},
      credentials: Relay.Redacted.wrap("client-secret"),
      target: device_target("hms-token", %{platform: "hms", app: "com.example.app"}),
      push: push
    })
  end

  describe "CH-24 CH-25 APNs adapter" do
    test "CH-24, CH-25, CH-19: the notification carries the policy headers, the delivery id and a signed provider token" do
      apns({200, [{"apns-id", "returned"}], ""})
      request = apns_request()

      assert {:accepted, %{provider_message_id: "returned"}} = Apns.deliver(request)
      assert_receive {:h2_request, _conn, _id, %{headers: headers, body: body}}

      expiration = Integer.to_string(DateTime.to_unix(request.push.expires_at))
      assert headers[":path"] == "/3/device/" <> @token
      assert headers["apns-push-type"] == "alert"
      assert headers["apns-priority"] == "10"
      assert headers["apns-topic"] == "com.example.app"
      assert headers["apns-id"] == Relay.Id.to_string(request.delivery_id)
      assert headers["apns-expiration"] == expiration

      "bearer " <> jwt = headers["authorization"]
      assert {:ok, %{"iss" => "TEAM123456"}} = Jwt.peek_claims(jwt)

      payload = Jason.decode!(body)
      assert payload["aps"]["alert"]["title"] == "Order shipped"
      assert payload["aps"]["interruption-level"] == "active"
      assert payload["relay"]["id"] == request.push.content_id
    end

    test "E-83: the renderer's encoded content is read and the primary link is the tap target" do
      apns({200, [], ""})
      output = %{"title" => "Order shipped", "body" => "On its way", "url" => @href}
      content = Jason.encode!(%{"channel" => "push", "locale" => "en", "output" => output})

      assert {:accepted, _info} = Apns.deliver(apns_request(%{content: content}))
      assert_receive {:h2_request, _conn, _id, %{body: body}}

      payload = Jason.decode!(body)
      assert payload["aps"]["alert"] == %{"title" => "Order shipped", "body" => "On its way"}
      assert payload["relay"]["url"] == @href
    end

    test "CH-11, CH-7: a 410 is reported raw with the time the token became invalid" do
      body = Jason.encode!(%{"reason" => "Unregistered", "timestamp" => 1_793_836_800_000})
      apns({410, [], body})

      assert {:rejected, %{code: "410/Unregistered", status: 410, timestamp: at}} =
               Apns.deliver(apns_request())

      assert at == DateTime.from_unix!(1_793_836_800_000, :millisecond)
    end

    test "CH-23, CH-33, CH-67: a sensitive notification goes content-free with the subject collapse id" do
      apns({200, [], ""})

      push =
        PushFixture.policy(%{
          sensitivity: "sensitive",
          subject_type: "order",
          subject_id: "42",
          lock_screen_body: "You have an update."
        })

      assert {:accepted, _info} = Apns.deliver(apns_request(%{push: push}))
      assert_receive {:h2_request, _conn, _id, %{headers: headers, body: body}}

      assert headers["apns-collapse-id"] == push.collapse.apns
      payload = Jason.decode!(body)
      assert payload["aps"]["mutable-content"] == 1
      assert payload["aps"]["alert"]["body"] == "You have an update."
      refute Map.has_key?(payload["aps"]["alert"], "subtitle")
      assert payload["relay"] == %{"id" => push.content_id}
    end

    test "CH-21: a raw override cannot change a policy field and is reported" do
      apns({200, [], ""})
      overrides = %{"raw" => %{"apns" => %{"headers" => %{"apns-priority" => "5"}}}}

      assert {:accepted, %{detail: %{override_ignored: ["apns.headers.apns-priority"]}}} =
               Apns.deliver(apns_request(%{overrides: overrides}))

      assert_receive {:h2_request, _conn, _id, %{headers: %{"apns-priority" => "10"}}}
    end

    test "CH-2: an account without its settings, or a request without a push policy, is not configured" do
      assert {:rejected, %{code: "relay:not_configured"}} =
               Apns.deliver(apns_request(%{account: %{"settings" => %{}}}))

      assert {:rejected, %{code: "relay:not_configured"}} =
               Apns.deliver(apns_request(%{push: nil}))
    end

    test "CH-9: an expired message is not sent" do
      push = PushFixture.policy(%{expires_at: ~U[2026-11-04 00:00:00Z]})
      assert Apns.deliver(apns_request(%{push: push})) == {:not_sent, "expired"}
    end
  end

  describe "CH-24 TN-30 FCM adapter" do
    test "CH-24, TN-30, CH-23: the message carries the policy, the class collapse key and a federated access token" do
      answer = {200, [], ~s({"name":"projects/p/messages/1"})}
      {:ok, port} = H2Server.start(fn _request -> answer end)
      parent = self()

      plug = fn conn ->
        send(parent, {:token_request, conn.request_path})
        Req.Test.json(conn, %{"access_token" => "federated", "expires_in" => 3600})
      end

      put_config(Fcm, origin: {:http, "localhost", port}, http: [plug: plug])

      settings = %{
        "project_id" => "demo-project",
        "auth" => "workload_identity",
        "audience" => @audience,
        "subject_token_type" => "urn:ietf:params:oauth:token-type:jwt"
      }

      push = PushFixture.policy(%{subject_type: "order", subject_id: "42", category: "orders"})

      request =
        PushFixture.request("fcm", %{
          account: %{"settings" => settings},
          credentials: Relay.Redacted.wrap("workload-token"),
          target: device_target("fcm-token", %{platform: "fcm", app: "com.example.app"}),
          push: push
        })

      assert {:accepted, %{provider_message_id: "projects/p/messages/1"}} = Fcm.deliver(request)

      assert_receive {:token_request, "/v1/token"}
      assert_receive {:h2_request, _conn, _id, %{headers: headers, body: body}}
      assert headers[":path"] == "/v1/projects/demo-project/messages:send"
      assert headers["authorization"] == "Bearer federated"

      message = Jason.decode!(body)["message"]
      assert message["token"] == "fcm-token"
      assert message["android"]["priority"] == "NORMAL"
      assert message["android"]["ttl"] == "3600s"
      assert message["android"]["collapse_key"] == "relay.transactional"
      assert message["android"]["notification"]["channel_id"] == "relay.orders.active"
      assert message["data"]["relay_topic"] == push.collapse.topic
    end
  end

  describe "CH-26 TN-31 Web Push and UnifiedPush adapters" do
    setup do
      {public, private} = :crypto.generate_key(:ecdh, :secp256r1)
      auth = :crypto.strong_rand_bytes(16)
      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:web_push, conn.req_headers, body})

        conn
        |> Plug.Conn.put_resp_header("location", "https://push.example/m/1")
        |> Plug.Conn.send_resp(201, "")
      end

      put_config(WebPush, http: [plug: plug])
      put_config(UnifiedPush, http: [plug: plug])

      keys = %{"p256dh" => Jwt.encode64(public), "auth" => Jwt.encode64(auth)}
      {:ok, vapid} = Relay.Keys.public_key(:es256, "vapid-app")

      settings = %{
        "vapid_subject" => "mailto:ops@example.com",
        "vapid_keys" => %{
          "web-app" => [%{"label" => "vapid-app", "public_key" => Jwt.encode64(vapid)}]
        }
      }

      %{private: private, auth: auth, keys: keys, settings: settings}
    end

    test "CH-26, TN-31, CH-65: the push is encrypted with TTL, Urgency, Topic and a VAPID token",
         ctx do
      push = PushFixture.policy(%{subject_type: "order", subject_id: "42"})
      account = %{"settings" => ctx.settings}
      request = web_request("web_push", ctx, %{account: account, push: push})

      assert {:accepted, %{provider_message_id: "https://push.example/m/1"}} =
               WebPush.deliver(request)

      assert_receive {:web_push, headers, body}
      headers = Map.new(headers)
      assert headers["ttl"] == "3600"
      assert headers["urgency"] == "normal"
      assert headers["topic"] == push.collapse.web_push
      assert "vapid t=" <> _rest = headers["authorization"]

      assert {:ok, plaintext} = Encryption.decrypt(body, ctx.private, ctx.auth)
      assert %{"title" => "Order shipped", "relay_id" => _id} = Jason.decode!(plaintext)
    end

    test "CH-26: a system message is never sent on Web Push", ctx do
      push = PushFixture.policy(%{message_class: "system", priority: "low"})
      account = %{"settings" => ctx.settings}
      request = web_request("web_push", ctx, %{account: account, push: push})

      assert {:rejected, %{code: "relay:silent_not_supported"}} = WebPush.deliver(request)
      refute_receive {:web_push, _headers, _body}
    end

    test "CH-1: UnifiedPush shares the Web Push module and sends without VAPID when none is set",
         ctx do
      request = web_request("unified_push", ctx, %{account: %{"settings" => %{}}})

      assert {:accepted, _info} = UnifiedPush.deliver(request)
      assert_receive {:web_push, headers, body}
      refute List.keymember?(headers, "authorization", 0)
      assert {:ok, _plaintext} = Encryption.decrypt(body, ctx.private, ctx.auth)
    end
  end

  describe "CH-27 HMS adapter" do
    test "CH-27: the class maps to the fixed HMS classification, never the tenant's" do
      hms(self(), %{"code" => "80000000", "msg" => "Success", "requestId" => "r1"})
      marketing = PushFixture.policy(%{message_class: "marketing"})

      assert {:accepted, %{provider_message_id: "r1"}} = Hms.deliver(hms_request(marketing))

      assert_receive {:hms, "/v1/1234/messages:send", headers, body}
      assert headers["authorization"] == "Bearer hms-token"
      android = Jason.decode!(body)["message"]["android"]
      assert android["notification"]["importance"] == "LOW"
      assert android["notification"]["click_action"] == %{"type" => 3}

      urgent = PushFixture.policy(%{message_class: "action_required"})
      assert {:accepted, _info} = Hms.deliver(hms_request(urgent))
      assert_receive {:hms, _path, _headers, body}
      android = Jason.decode!(body)["message"]["android"]
      assert android["urgency"] == "HIGH"
      assert android["notification"]["importance"] == "NORMAL"
    end

    test "E-83: the primary link travels in the data as relay_url" do
      hms(self(), %{"code" => "80000000", "msg" => "Success", "requestId" => "r2"})
      content = %{"title" => "Order shipped", "body" => "On its way", "url" => @href}
      request = %{hms_request(PushFixture.policy()) | content: content}

      assert {:accepted, _info} = Hms.deliver(request)
      assert_receive {:hms, _path, _headers, body}
      data = Jason.decode!(Jason.decode!(body)["message"]["data"])
      assert data["relay_url"] == @href
    end

    test "CH-7: an HMS result code is reported raw" do
      hms(self(), %{"code" => "80300007", "msg" => "All tokens are invalid"})

      assert {:rejected, %{code: "80300007"}} = Hms.deliver(hms_request(PushFixture.policy()))
    end
  end
end
