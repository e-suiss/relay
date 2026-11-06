defmodule Relay.Channels.SettingsCheckTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Email.Esp
  alias Relay.Channels.ProviderHttp
  alias Relay.Channels.SettingsCheck

  @streams %{
    "transactional" => %{"domain" => "sender.example"},
    "marketing" => %{"domain" => "news.sender.example"}
  }

  defp check(provider, credentials, settings \\ %{}) do
    account = %{"id" => Relay.Id.generate(), "provider" => provider, "settings" => settings}
    wrapped = credentials && Relay.Redacted.wrap(credentials)
    Relay.Channels.check_settings(account, wrapped, 1_000)
  end

  defp esp(fun), do: Req.Test.stub(Esp, fun)
  defp http(fun), do: Req.Test.stub(ProviderHttp, fun)

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "CH-14 CH-52 plan" do
    test "CH-14: a verification verifies on success and fails closed otherwise" do
      assert %{verification: {"verified", nil}, health: "healthy", retry: false} =
               SettingsCheck.plan(:verify, :ok, false)

      assert %{verification: {"failed", "channel.provider_check_unsupported"}, health: nil} =
               SettingsCheck.plan(:verify, :unsupported, false)

      assert %{verification: nil, retry: true} =
               SettingsCheck.plan(:verify, {:error, "http_5xx"}, false)

      assert %{verification: {"failed", "channel.provider_check_unavailable"}, health: "down"} =
               SettingsCheck.plan(:verify, {:error, "http_5xx"}, true)
    end

    test "CH-52: a mismatch drops the account in both modes and carries the setting" do
      mismatch = {:mismatch, %{"setting" => "delivery_type", "expected" => "Live"}}

      for mode <- [:verify, :recheck] do
        plan = SettingsCheck.plan(mode, mismatch, false)
        assert plan.verification == {"failed", "channel.provider_settings_mismatch"}
        assert plan.health == "degraded"

        assert plan.mismatch == %{
                 "setting" => "delivery_type",
                 "expected" => "Live",
                 "actual" => nil
               }
      end
    end

    test "CH-52: a periodic check never verifies again; it records the health only" do
      assert %{verification: nil, health: "healthy"} = SettingsCheck.plan(:recheck, :ok, true)

      assert %{verification: nil, health: "down", retry: false} =
               SettingsCheck.plan(:recheck, {:error, "timeout"}, true)

      assert %{verification: nil, health: nil} = SettingsCheck.plan(:recheck, :unsupported, true)
    end

    test "CH-52: the adapters with a settings check are the providers that answer one" do
      providers = Relay.Channels.settings_check_providers()

      for provider <- ~w(fake postmark sendgrid mailgun ses whatsapp_cloud slack telegram),
          do: assert(provider in providers, provider)

      refute "teams" in providers
      assert check("teams", "token") == :unsupported
      assert check("nothing", nil) == :unsupported
    end
  end

  describe "CH-52 adapter settings checks" do
    test "CH-52: Postmark holds for a live server and a sandbox server is a mismatch" do
      parent = self()

      esp(fn conn ->
        token = Plug.Conn.get_req_header(conn, "x-postmark-server-token")
        send(parent, {:called, conn.method, conn.request_path, token})
        Req.Test.json(conn, %{"Name" => "Relay", "DeliveryType" => "Live"})
      end)

      assert check("postmark", %{"server_token" => "pm-1"}) == :ok
      assert_received {:called, "GET", "/server", ["pm-1"]}

      esp(&Req.Test.json(&1, %{"DeliveryType" => "Sandbox"}))

      assert {:mismatch, %{"setting" => "delivery_type", "actual" => "Sandbox"}} =
               check("postmark", %{"server_token" => "pm-1"})

      esp(&json(&1, 401, %{"ErrorCode" => 10}))

      assert {:mismatch, %{"setting" => "credentials", "actual" => "http_401"}} =
               check("postmark", %{"server_token" => "x"})

      esp(&json(&1, 503, %{}))
      assert check("postmark", %{"server_token" => "pm-1"}) == {:error, "http_503"}
      assert {:mismatch, %{"setting" => "credentials"}} = check("postmark", nil)
    end

    test "CH-14, CH-52: SendGrid needs every stream domain authenticated and valid" do
      settings = %{"streams" => @streams}

      esp(fn conn ->
        assert conn.request_path == "/v3/whitelabel/domains"
        Req.Test.json(conn, [%{"domain" => "sender.example", "valid" => true}])
      end)

      assert check("sendgrid", %{"api_key" => "sg"}, settings) == :ok

      esp(&Req.Test.json(&1, [%{"domain" => "sender.example", "valid" => false}]))

      assert {:mismatch, %{"setting" => "domain_authentication", "actual" => domain}} =
               check("sendgrid", %{"api_key" => "sg"}, settings)

      assert domain == "news.sender.example"
    end

    test "CH-14, CH-52: Mailgun needs every stream domain active" do
      settings = %{"streams" => @streams, "mailgun" => %{"region" => "eu"}}
      parent = self()

      esp(fn conn ->
        send(parent, {:host, conn.host, conn.request_path})

        Req.Test.json(conn, %{
          "items" => [
            %{"name" => "sender.example", "state" => "active"},
            %{"name" => "news.sender.example", "state" => "unverified"}
          ]
        })
      end)

      assert {:mismatch, %{"setting" => "domain_state", "actual" => "news.sender.example"}} =
               check("mailgun", %{"api_key" => "mg"}, settings)

      assert_received {:host, "api.eu.mailgun.net", "/v4/domains"}
    end

    test "CH-52: SES must be enabled for sending and out of the sandbox" do
      credentials = %{"access_key_id" => "AKIA", "secret_access_key" => "secret"}
      settings = %{"ses" => %{"region" => "eu-central-1"}}

      esp(fn conn ->
        assert conn.request_path == "/v2/email/account"
        assert [_signature] = Plug.Conn.get_req_header(conn, "authorization")
        Req.Test.json(conn, %{"SendingEnabled" => true, "ProductionAccessEnabled" => true})
      end)

      assert check("ses", credentials, settings) == :ok

      esp(&Req.Test.json(&1, %{"SendingEnabled" => true, "ProductionAccessEnabled" => false}))

      assert {:mismatch, %{"setting" => "production_access"}} =
               check("ses", credentials, settings)

      assert {:mismatch, %{"setting" => "region"}} = check("ses", credentials, %{})
    end

    test "CH-52, CH-61: a WhatsApp number must be connected" do
      settings = %{"phone_number_id" => "1065"}
      parent = self()

      http(fn conn ->
        send(parent, {:path, conn.request_path, conn.query_string})
        json(conn, 200, %{"id" => "1065", "status" => "CONNECTED"})
      end)

      assert check("whatsapp_cloud", "system-user-token", settings) == :ok
      assert_received {:path, "/v24.0/1065", query}
      assert query =~ "fields="

      http(&json(&1, 200, %{"id" => "1065", "status" => "FLAGGED"}))

      assert {:mismatch, %{"setting" => "phone_number_status", "actual" => "FLAGGED"}} =
               check("whatsapp_cloud", "system-user-token", settings)

      assert {:mismatch, %{"setting" => "phone_number_id"}} =
               check("whatsapp_cloud", "system-user-token", %{})
    end

    test "CH-52, CH-62: a Slack token must be accepted and belong to the installed workspace" do
      settings = %{"workspace_id" => "T1"}

      http(&json(&1, 200, %{"ok" => true, "team_id" => "T1"}))
      assert check("slack", "xoxb-1", settings) == :ok

      http(&json(&1, 200, %{"ok" => true, "team_id" => "T2"}))

      assert {:mismatch, %{"setting" => "workspace_id", "expected" => "T1", "actual" => "T2"}} =
               check("slack", "xoxb-1", settings)

      http(&json(&1, 200, %{"ok" => false, "error" => "token_revoked"}))
      assert {:mismatch, %{"setting" => "credentials"}} = check("slack", "xoxb-1", settings)

      http(&json(&1, 200, %{"ok" => false, "error" => "internal_error"}))
      assert check("slack", "xoxb-1", settings) == {:error, "internal_error"}
    end

    test "CH-52, CH-62: a Telegram bot keeps its webhook" do
      http(&json(&1, 200, %{"ok" => true, "result" => %{"url" => "https://relay.example/t"}}))
      assert check("telegram", ~s({"bot_token":"123:abc"})) == :ok

      http(&json(&1, 200, %{"ok" => true, "result" => %{"url" => ""}}))

      assert {:mismatch, %{"setting" => "webhook_url"}} =
               check("telegram", ~s({"bot_token":"123:abc"}))

      http(&json(&1, 401, %{"ok" => false, "error_code" => 401}))
      assert {:mismatch, %{"setting" => "credentials"}} = check("telegram", "123:abc")
      assert {:mismatch, %{"setting" => "credentials"}} = check("telegram", nil)
    end

    test "CH-52: a transport failure is an error, never a mismatch" do
      http(&Req.Test.transport_error(&1, :timeout))
      assert {:error, _reason} = check("slack", "xoxb-1", %{})
      assert check("fake", nil) == :ok
    end
  end
end
