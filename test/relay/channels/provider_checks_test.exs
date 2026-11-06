defmodule Relay.Channels.ProviderChecksTest do
  use ExUnit.Case, async: false

  alias Relay.Channels.Apns
  alias Relay.Channels.Fcm
  alias Relay.Channels.Hms
  alias Relay.Channels.ProviderHttp
  alias Relay.Channels.Push.Jwt
  alias RelayTest.H2Server
  alias RelayTest.SmtpServer

  @apns %{
    "team_id" => "TEAM123456",
    "key_id" => "KEY1234567",
    "key_label" => "apns-team-key",
    "bundle_id" => "com.example.app"
  }
  @audience "//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/q"
  @fcm %{
    "project_id" => "demo-project",
    "auth" => "workload_identity",
    "audience" => @audience,
    "subject_token_type" => "urn:ietf:params:oauth:token-type:jwt"
  }
  @hms %{"app_id" => "1234", "client_id" => "1234"}
  @teams %{"app_id" => "bot-app", "app_password" => "bot-secret"}

  defp check(provider, credentials, settings, fields \\ %{}) do
    account =
      Map.merge(
        %{
          "id" => Relay.Id.generate(),
          "tenant_id" => Relay.Id.generate(),
          "environment" => "live",
          "provider" => provider,
          "settings" => settings
        },
        fields
      )

    wrapped = credentials && Relay.Redacted.wrap(credentials)
    Relay.Channels.check_settings(account, wrapped, 5_000)
  end

  defp put_config(adapter, config) do
    previous = Application.get_env(:relay, adapter)
    Application.put_env(:relay, adapter, config)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:relay, adapter, previous),
        else: Application.delete_env(:relay, adapter)
    end)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp http(fun), do: Req.Test.stub(ProviderHttp, fun)

  defp apns(status, reason) do
    body = if reason, do: Jason.encode!(%{"reason" => reason}), else: ""
    {:ok, port} = H2Server.start(fn _request -> {status, [], body} end)
    put_config(Apns, origins: %{"production" => {:http, "localhost", port}})
  end

  defp fcm(answer, token \\ {200, %{"access_token" => "federated", "expires_in" => 3600}}) do
    {:ok, port} = H2Server.start(fn _request -> answer end)
    {status, body} = token
    put_config(Fcm, origin: {:http, "localhost", port}, http: [plug: &json(&1, status, body)])
  end

  defp hms(answer, token_status \\ 200) do
    parent = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if String.ends_with?(conn.request_path, "/token") do
        json(conn, token_status, %{"access_token" => "hms-token", "expires_in" => 3600})
      else
        send(parent, {:hms, conn.request_path, Map.new(conn.req_headers), body})
        json(conn, 200, answer)
      end
    end

    put_config(Hms,
      token_url: "https://oauth.example/oauth2/v3/token",
      send_url: "https://push.example/v1/",
      http: [plug: plug]
    )
  end

  defp vapid(label, public_label \\ nil) do
    {:ok, public} = Relay.Keys.public_key(:es256, public_label || label)

    %{
      "vapid_subject" => "mailto:ops@example.com",
      "vapid_keys" => %{
        "web-app" => [%{"label" => label, "public_key" => Jwt.encode64(public)}]
      }
    }
  end

  defp pem(cacerts),
    do: :public_key.pem_encode(for(der <- cacerts, do: {:Certificate, der, :not_encrypted}))

  defp smtp(port, pem, mode \\ "starttls") do
    smtp = %{"host" => "localhost", "port" => port, "tls" => mode, "ca_certificates" => pem}
    %{"smtp" => smtp}
  end

  defp session do
    receive do
      {:smtp_session, session} -> session
    after
      5_000 -> flunk("no SMTP session")
    end
  end

  describe "CH-14 CH-52 APNs settings check" do
    test "CH-14: BadDeviceToken for an unknown device holds the team, key and bundle" do
      apns(400, "BadDeviceToken")

      assert check("apns", nil, @apns) == :ok
      assert_receive {:h2_request, _conn, _id, %{headers: headers, body: body}}
      assert headers[":path"] == "/3/device/" <> String.duplicate("0", 64)
      assert headers["apns-topic"] == "com.example.app"
      assert headers["apns-push-type"] == "background"

      "bearer " <> jwt = headers["authorization"]
      assert {:ok, %{"iss" => "TEAM123456"}} = Jwt.peek_claims(jwt)
      assert Jason.decode!(body) == %{"aps" => %{"content-available" => 1}}
    end

    test "CH-52: a refused provider token is a credential mismatch" do
      apns(403, "InvalidProviderToken")

      assert {:mismatch, %{"setting" => "credentials", "actual" => "403/InvalidProviderToken"}} =
               check("apns", nil, @apns)
    end

    test "CH-52: a refused topic is a bundle mismatch" do
      apns(400, "TopicDisallowed")

      assert {:mismatch, %{"setting" => "bundle_id", "expected" => "com.example.app"}} =
               check("apns", nil, @apns)
    end

    test "CH-14: a server error is an error and missing settings a mismatch" do
      apns(500, "InternalServerError")
      assert check("apns", nil, @apns) == {:error, "500/InternalServerError"}

      assert {:mismatch, %{"setting" => "bundle_id", "expected" => "set"}} =
               check("apns", nil, Map.delete(@apns, "bundle_id"))
    end
  end

  describe "CH-14 CH-52 FCM settings check" do
    test "CH-14: a validate_only message to a topic holds the project's credentials" do
      fcm({200, [], ~s({"name":"projects/demo-project/messages/fake"})})

      assert check("fcm", "workload-token", @fcm) == :ok
      assert_receive {:h2_request, _conn, _id, %{headers: headers, body: body}}
      assert headers[":path"] == "/v1/projects/demo-project/messages:send"
      assert headers["authorization"] == "Bearer federated"

      assert Jason.decode!(body) == %{
               "validate_only" => true,
               "message" => %{"topic" => "relay-settings-check"}
             }
    end

    test "CH-52: a refused token is a credential mismatch and an unavailable one an error" do
      fcm({200, [], "{}"}, {400, %{"error" => "invalid_grant"}})

      assert {:mismatch, %{"setting" => "credentials", "actual" => "token_http_400"}} =
               check("fcm", "workload-token", @fcm)

      fcm({200, [], "{}"}, {503, %{}})
      assert check("fcm", "workload-token", @fcm) == {:error, "token_http_503"}

      assert {:mismatch, %{"setting" => "credentials"}} = check("fcm", nil, @fcm)
    end

    test "CH-52: a refused message is a credential mismatch and an unknown project a mismatch" do
      denied = ~s({"error":{"code":403,"status":"PERMISSION_DENIED"}})
      fcm({403, [], denied})

      assert {:mismatch, %{"setting" => "credentials", "actual" => "rpc:PERMISSION_DENIED"}} =
               check("fcm", "workload-token", @fcm)

      fcm({404, [], ~s({"error":{"code":404,"status":"NOT_FOUND"}})})

      assert {:mismatch, %{"setting" => "project_id", "expected" => "demo-project"}} =
               check("fcm", "workload-token", @fcm)

      assert {:mismatch, %{"setting" => "auth"}} =
               check("fcm", nil, %{"project_id" => "demo-project"})
    end
  end

  describe "CH-14 CH-52 HMS settings check" do
    test "CH-14: a validate_only message to a topic holds the app's client credentials" do
      hms(%{"code" => "80000000", "msg" => "Success"})

      assert check("hms", "client-secret", @hms) == :ok
      assert_receive {:hms, "/v1/1234/messages:send", headers, body}
      assert headers["authorization"] == "Bearer hms-token"
      assert %{"validate_only" => true, "message" => %{"topic" => _topic}} = Jason.decode!(body)
    end

    test "CH-52: a refused client or an OAuth result code is a credential mismatch" do
      hms(%{"code" => "80000000"}, 401)

      assert {:mismatch, %{"setting" => "credentials", "actual" => "token_http_401"}} =
               check("hms", "client-secret", @hms)

      hms(%{"code" => "80200001", "msg" => "Oauth authentication error"})

      assert {:mismatch, %{"setting" => "credentials", "actual" => "80200001"}} =
               check("hms", "client-secret", @hms)

      hms(%{"code" => "80000000"}, 502)
      assert check("hms", "client-secret", @hms) == {:error, "token_http_502"}
      assert {:mismatch, %{"setting" => "credentials"}} = check("hms", nil, @hms)
    end
  end

  describe "CH-14 CH-52 Web Push and UnifiedPush identity check" do
    test "CH-14: every listed VAPID key is in the key store and signs" do
      assert check("web_push", nil, vapid("vapid-app")) == :ok
      assert check("unified_push", nil, vapid("vapid-app")) == :ok
    end

    test "CH-52: a listed public key that is not the key store's is a mismatch" do
      assert {:mismatch, %{"setting" => "vapid_public_key", "expected" => "vapid-app"}} =
               check("web_push", nil, vapid("vapid-app", "another-key"))
    end

    test "CH-14: Web Push needs an identity, UnifiedPush holds without one" do
      assert {:mismatch, %{"setting" => "vapid_keys", "expected" => "set"}} =
               check("web_push", nil, %{})

      assert check("unified_push", nil, %{}) == :ok

      invalid = %{vapid("vapid-app") | "vapid_subject" => "ops@example.com"}

      assert {:mismatch, %{"setting" => "vapid_keys", "actual" => "web-app"}} =
               check("web_push", nil, invalid)
    end
  end

  describe "CH-14 CH-52 SMTP settings check" do
    setup do
      certs = SmtpServer.certificates()
      %{certs: certs, pem: pem(certs.cacerts)}
    end

    test "CH-14: the session greets, upgrades to TLS, authenticates and quits without a message",
         ctx do
      {:ok, port} = SmtpServer.start(mode: :starttls, tls: ctx.certs.server, auth: true)
      credentials = %{"username" => "relay", "password" => "s3cret"}

      assert check("smtp", credentials, smtp(port, ctx.pem)) == :ok

      session = session()
      assert session.tls
      assert session.auth == "AUTH PLAIN " <> Base.encode64(<<0, "relay", 0, "s3cret">>)
      assert session.mail_from == nil
      assert session.data == nil
    end

    test "CH-52: a refused login is a credential mismatch", ctx do
      {:ok, port} =
        SmtpServer.start(
          mode: :starttls,
          tls: ctx.certs.server,
          auth: true,
          auth_reply: "535 5.7.8 authentication failed"
        )

      credentials = %{"username" => "relay", "password" => "wrong"}

      assert {:mismatch, %{"setting" => "credentials", "actual" => "auth_failed"}} =
               check("smtp", credentials, smtp(port, ctx.pem))
    end

    test "CH-52: a server without STARTTLS or with an untrusted certificate is a TLS mismatch",
         ctx do
      {:ok, port} = SmtpServer.start(mode: :starttls, tls: ctx.certs.server, starttls: false)

      assert {:mismatch, %{"setting" => "tls", "expected" => "offered"}} =
               check("smtp", nil, smtp(port, ctx.pem))

      {:ok, port} = SmtpServer.start(mode: :implicit, tls: ctx.certs.server)
      untrusted = SmtpServer.certificates()

      assert {:mismatch, %{"setting" => "tls", "expected" => "verified"}} =
               check("smtp", nil, smtp(port, pem(untrusted.cacerts), "implicit"))
    end

    test "CH-14: invalid settings are a mismatch", ctx do
      assert {:mismatch, %{"setting" => "smtp"}} = check("smtp", nil, smtp(1025, ctx.pem, "none"))
    end
  end

  describe "CH-14 CH-52 SMS settings checks" do
    test "CH-52: Netgsm's balance holds the user code and password; code 30 is a mismatch" do
      parent = self()

      http(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:netgsm, conn.request_path, Jason.decode!(body)})
        json(conn, 200, %{"balance" => [%{"amount" => 10, "balance_name" => "sms"}]})
      end)

      assert check("netgsm", "pass", %{"usercode" => "8501234567"}) == :ok
      assert_received {:netgsm, "/balance", %{"usercode" => "8501234567", "password" => "pass"}}

      http(&json(&1, 200, %{"code" => "30"}))

      assert {:mismatch, %{"setting" => "credentials", "actual" => "balance:30"}} =
               check("netgsm", "wrong", %{"usercode" => "8501234567"})

      http(&json(&1, 503, %{}))
      assert check("netgsm", "pass", %{"usercode" => "8501234567"}) == {:error, "http_503"}
      assert {:mismatch, %{"setting" => "credentials"}} = check("netgsm", nil, %{})
    end

    test "CH-52: Verimor's balance holds an SMS account and a voice account's API key" do
      parent = self()

      http(fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(parent, {:verimor, conn.host, conn.request_path, conn.query_params})
        Plug.Conn.send_resp(conn, 200, "125.0")
      end)

      assert check("verimor", "pass", %{"username" => "908501234567"}) == :ok

      sms = %{"username" => "908501234567", "password" => "pass"}
      assert_received {:verimor, "sms.verimor.com.tr", "/v2/balance", ^sms}

      assert check("verimor", "api-key", %{}, %{"channel" => "voice"}) == :ok
      assert_received {:verimor, "api.bulutsantralim.com", "/balance", %{"key" => "api-key"}}

      http(&Plug.Conn.send_resp(&1, 401, "Unauthorized"))

      assert {:mismatch, %{"setting" => "credentials", "actual" => "http_401"}} =
               check("verimor", "wrong", %{"username" => "908501234567"})
    end
  end

  describe "CH-14 CH-52 messaging settings checks" do
    test "CH-52: a Teams bot is checked by its Bot Framework token" do
      parent = self()

      http(fn conn ->
        send(parent, {:teams, conn.host, conn.request_path})
        json(conn, 200, %{"access_token" => "bf-token", "expires_in" => 3600})
      end)

      assert check("teams", Jason.encode!(@teams), %{}) == :ok
      assert_received {:teams, "login.microsoftonline.com", "/botframework.com/oauth2/v2.0/token"}

      http(&json(&1, 400, %{"error" => "invalid_client"}))

      assert {:mismatch, %{"setting" => "credentials", "actual" => "token_invalid_client"}} =
               check("teams", Jason.encode!(@teams), %{})

      http(&json(&1, 503, %{}))
      assert check("teams", Jason.encode!(@teams), %{}) == {:error, "http_503"}
      assert {:mismatch, %{"setting" => "credentials"}} = check("teams", nil, %{})
    end

    test "CH-52: a Discord bot is checked by its own user" do
      parent = self()

      http(fn conn ->
        authorization = Plug.Conn.get_req_header(conn, "authorization")
        send(parent, {:discord, conn.request_path, authorization})
        json(conn, 200, %{"id" => "1", "bot" => true})
      end)

      assert check("discord", "bot-token", %{}) == :ok
      assert_received {:discord, "/api/v10/users/@me", ["Bot bot-token"]}

      http(&json(&1, 401, %{"code" => 0, "message" => "401: Unauthorized"}))

      assert {:mismatch, %{"setting" => "credentials", "actual" => "http_401"}} =
               check("discord", "bad-token", %{})
    end
  end
end
