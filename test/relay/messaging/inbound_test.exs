defmodule Relay.Messaging.InboundTest do
  use ExUnit.Case, async: true

  alias Relay.Messaging.Inbound
  alias Relay.Messaging.Install
  alias Relay.Messaging.TeamsAuth
  alias Relay.Redacted

  @now ~U[2026-11-05 10:00:00Z]

  defp secret(map), do: Redacted.wrap(Jason.encode!(map))

  defp slack_headers(signing, body, ts) do
    mac = :crypto.mac(:hmac, :sha256, signing, "v0:" <> ts <> ":" <> body)

    [
      {"x-slack-request-timestamp", ts},
      {"x-slack-signature", "v0=" <> Base.encode16(mac, case: :lower)}
    ]
  end

  describe "CH-62 T-40 signatures on the raw body" do
    test "CH-62: a Slack request verifies with the app's signing secret and a stale one does not" do
      body = ~s({"type":"event_callback","event_id":"Ev1","event":{"type":"message"}})
      key = secret(%{"signing_secret" => "shh", "client_secret" => "c"})
      ts = Integer.to_string(DateTime.to_unix(@now))

      assert :ok = Inbound.verify("slack", key, body, slack_headers("shh", body, ts), @now)

      assert {:error, :bad_signature} =
               Inbound.verify("slack", key, body, slack_headers("other", body, ts), @now)

      old = Integer.to_string(DateTime.to_unix(@now) - 600)

      assert {:error, :stale_timestamp} =
               Inbound.verify("slack", key, body, slack_headers("shh", body, old), @now)
    end

    test "CH-62: Telegram's secret token is derived from the bot token and compared" do
      key = secret(%{"bot_token" => "123:abc"})
      token = Redacted.expose(Install.telegram_secret(%{secret: key}))
      assert token =~ ~r/^[A-Za-z0-9_-]{43}$/
      header = "x-telegram-bot-api-secret-token"

      assert :ok = Inbound.verify("telegram", key, "{}", [{header, token}], @now)
      assert {:error, _reason} = Inbound.verify("telegram", key, "{}", [{header, "x"}], @now)
      assert {:error, :missing_header} = Inbound.verify("telegram", key, "{}", [], @now)
    end

    test "CH-62: a Discord interaction verifies with the application's Ed25519 key" do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      key = secret(%{"public_key" => Base.encode16(public, case: :lower)})
      body = ~s({"type":1})
      ts = Integer.to_string(DateTime.to_unix(@now))
      signature = :crypto.sign(:eddsa, :none, ts <> body, [private, :ed25519])

      headers = [
        {"x-signature-ed25519", Base.encode16(signature, case: :lower)},
        {"x-signature-timestamp", ts}
      ]

      assert :ok = Inbound.verify("discord", key, body, headers, @now)
      assert {:error, :bad_signature} = Inbound.verify("discord", key, body <> " ", headers, @now)
    end

    test "CH-62: a Teams request without a bearer token is refused" do
      assert {:error, :bad_signature} = TeamsAuth.verify(nil, "app", nil, @now, [])
      assert {:error, :bad_signature} = TeamsAuth.verify("Bearer a.b", "app", nil, @now, [])
    end

    test "T-40: an RSA JWK becomes a PEM public key" do
      {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} =
        :public_key.generate_key({:rsa, 2048, 65_537})

      encode = &Base.url_encode64(:binary.encode_unsigned(&1), padding: false)
      assert {:ok, "-----BEGIN PUBLIC KEY-----" <> _} = TeamsAuth.pem(encode.(n), encode.(e))
    end
  end

  describe "CH-62 WH-49 provider events" do
    test "CH-62: Slack's URL verification is answered and an event is deduplicated by event_id" do
      challenge = ~s({"type":"url_verification","challenge":"abc"})
      assert {:reply, %{"challenge" => "abc"}} = Inbound.parse("slack", challenge, nil)

      body =
        Jason.encode!(%{
          "type" => "event_callback",
          "event_id" => "Ev1",
          "team_id" => "T1",
          "event" => %{
            "type" => "message",
            "channel" => "D1",
            "user" => "U1",
            "text" => "ok",
            "thread_ts" => "1.1"
          }
        })

      assert {:event, event, nil} = Inbound.parse("slack", body, "application/json")
      assert %{event_id: "Ev1", kind: "message", workspace: "T1", message_ref: "D1:1.1"} = event
    end

    test "CH-62, INV-29: a Slack button is an action event, never an approval" do
      payload = %{
        "type" => "block_actions",
        "team" => %{"id" => "T1"},
        "user" => %{"id" => "U1"},
        "channel" => %{"id" => "C1"},
        "container" => %{"message_ts" => "2.2"},
        "actions" => [%{"action_id" => "relay_link"}]
      }

      raw = URI.encode_query(%{"payload" => Jason.encode!(payload)})
      form = "application/x-www-form-urlencoded"
      assert {:event, event, nil} = Inbound.parse("slack", raw, form)
      assert %{kind: "action", action: "relay_link", message_ref: "C1:2.2"} = event
      assert event.event_id == "body:" <> Inbound.digest(raw)
      refute Map.has_key?(event, :approval)
    end

    test "CH-62: Telegram updates are deduplicated by update_id" do
      update = %{
        "update_id" => 77,
        "message" => %{
          "message_id" => 9,
          "chat" => %{"id" => 42},
          "from" => %{"id" => 42},
          "text" => "hi",
          "reply_to_message" => %{"message_id" => 8}
        }
      }

      assert {:event, event, nil} = Inbound.parse("telegram", Jason.encode!(update), nil)
      assert %{event_id: "77", kind: "message", message_ref: "42:8", text: "hi"} = event

      blocked = %{
        "update_id" => 78,
        "my_chat_member" => %{
          "chat" => %{"id" => 42},
          "from" => %{"id" => 42},
          "new_chat_member" => %{"status" => "kicked"}
        }
      }

      assert {:event, %{kind: "membership", action: "kicked"}, nil} =
               Inbound.parse("telegram", Jason.encode!(blocked), nil)
    end

    test "CH-62: Discord's PING is answered and a component is acknowledged without a reply" do
      assert {:reply, %{"type" => 1}} = Inbound.parse("discord", ~s({"type":1}), nil)

      click = %{
        "type" => 3,
        "id" => "i1",
        "guild_id" => "g1",
        "member" => %{"user" => %{"id" => "u1"}},
        "message" => %{"id" => "m1", "channel_id" => "c1"},
        "data" => %{"custom_id" => "relay_link"}
      }

      assert {:event, event, %{"type" => 6}} = Inbound.parse("discord", Jason.encode!(click), nil)
      assert %{event_id: "i1", kind: "action", workspace: "g1", message_ref: "c1:m1"} = event
    end

    test "CH-62: a Teams installation update carries the conversation reference" do
      activity = %{
        "id" => "a1",
        "type" => "installationUpdate",
        "serviceUrl" => "https://smba.trafficmanager.net/emea/",
        "conversation" => %{"id" => "a:1x"},
        "from" => %{"aadObjectId" => "aad-1"},
        "channelData" => %{"tenant" => %{"id" => "tenant-1"}}
      }

      assert {:event, event, nil} = Inbound.parse("teams", Jason.encode!(activity), nil)
      assert %{kind: "conversation", workspace: "tenant-1", action: "installationUpdate"} = event

      assert event.reference == %{
               "service_url" => "https://smba.trafficmanager.net/emea/",
               "conversation_id" => "a:1x"
             }
    end
  end
end
