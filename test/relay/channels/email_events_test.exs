defmodule Relay.Channels.EmailEventsTest do
  use ExUnit.Case, async: true

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Email.Bundled
  alias Relay.Channels.Email.Event
  alias Relay.Channels.Email.Sns
  alias Relay.Channels.Mailgun
  alias Relay.Channels.Postmark
  alias Relay.Channels.Sendgrid
  alias Relay.Channels.Ses

  @topic "arn:aws:sns:eu-central-1:123456789012:relay"
  @cert_url "https://sns.eu-central-1.amazonaws.com/SimpleNotificationService-abc.pem"

  setup_all do
    {:ok, content} = ChannelDeclarations.compose()
    %{declarations: ChannelDeclarations.new(content, nil)}
  end

  defp table, do: Bundled.content("email_bounce_codes")

  defp delivery_id, do: Relay.Id.generate()

  defp classify(event, ctx), do: Event.classify(event, ctx.declarations, table())

  describe "CH-47 correlation" do
    test "CH-47: the delivery is read from the correlation value or from Relay's Message-ID" do
      id = delivery_id()
      text = Relay.Id.to_string(id)

      assert Event.delivery_id(text) == id
      assert Event.delivery_id("<" <> text <> "@sender.example>") == id
      assert Event.delivery_id("<other@sender.example>") == nil
      assert Event.first_delivery_id([nil, "x", text]) == id
    end
  end

  describe "CH-39 CH-77 Postmark events" do
    test "CH-39: a hard bounce with a 5.1.1 diagnostic suppresses the subscriber", ctx do
      id = delivery_id()

      body =
        Jason.encode!(%{
          "RecordType" => "Bounce",
          "Type" => "HardBounce",
          "ID" => 42,
          "MessageID" => "pm-1",
          "Email" => "reader@example.com",
          "Details" => "smtp;550 5.1.1 The email account that you tried to reach does not exist",
          "BouncedAt" => "2026-11-05T10:00:00Z",
          "Metadata" => %{"relay_delivery_id" => Relay.Id.to_string(id)}
        })

      assert [%Event{type: :bounced, status: "5.1.1", delivery_id: ^id, id: "42"} = event] =
               Postmark.events(body)

      assert Relay.Redacted.expose(event.recipient) == "reader@example.com"
      assert %{kind: :hard, suppression: "hard_bounce", reputation: :bounce} =
               classify(event, ctx)
    end

    test "CH-39: a DMARC policy bounce never suppresses the subscriber", ctx do
      [event] = Postmark.events(%{"RecordType" => "Bounce", "Type" => "DMARCPolicy"})
      result = classify(event, ctx)

      assert result.kind == :sender_config
      assert result.suppression == nil
      assert result.rule == "event:DMARCPolicy"
    end

    test "CH-40: a spam complaint suppresses and counts toward reputation", ctx do
      record = %{"RecordType" => "SpamComplaint", "Email" => "reader@example.com"}
      [event] = Postmark.events(record)

      assert %{kind: :complaint, suppression: "complaint", reputation: :complaint} =
               classify(event, ctx)
    end

    test "CH-8: an unmapped bounce type is unknown and touches nothing", ctx do
      [event] = Postmark.events(%{"RecordType" => "Bounce", "Type" => "Unknown"})
      assert %{kind: :unknown, suppression: nil} = classify(event, ctx)
    end
  end

  describe "CH-39 CH-47 SendGrid events" do
    test "CH-39: a webhook array yields a delivery, a sender configuration bounce and a complaint",
         ctx do
      id = Relay.Id.to_string(delivery_id())

      body =
        Jason.encode!([
          %{"event" => "delivered", "email" => "a@example.com", "relay_delivery_id" => id},
          %{
            "event" => "bounce",
            "type" => "bounce",
            "status" => "5.7.26",
            "reason" => "550 5.7.26 unauthenticated mail is prohibited",
            "email" => "b@example.com"
          },
          %{"event" => "spamreport", "email" => "c@example.com"},
          %{"event" => "processed", "email" => "d@example.com"}
        ])

      [delivered, bounce, complaint, processed] = Sendgrid.events(body)

      assert delivered.type == :delivered
      assert Relay.Id.to_string(delivered.delivery_id) == id
      assert %{kind: :sender_config, suppression: nil} = classify(bounce, ctx)
      assert %{kind: :complaint} = classify(complaint, ctx)
      assert processed.type == :ignored
      assert classify(processed, ctx) == nil
    end
  end

  describe "CH-39 T-40 Mailgun events" do
    test "CH-39: a permanent failure is a hard bounce" do
      body = %{
        "event-data" => %{
          "event" => "failed",
          "severity" => "permanent",
          "recipient" => "reader@example.com",
          "delivery-status" => %{"code" => 550, "message" => "5.1.1 mailbox unavailable"}
        }
      }

      assert [%Event{type: :bounced, code: "failed:permanent"} = event] = Mailgun.events(body)
      {:ok, content} = ChannelDeclarations.compose()
      declarations = ChannelDeclarations.new(content, nil)
      assert %{kind: :hard} = Event.classify(event, declarations, table())
    end

    test "T-40: the signature of timestamp and token is checked in constant time and kept fresh" do
      key = Relay.Redacted.wrap("mg-signing-key")
      now = ~U[2026-11-05 10:00:00Z]
      timestamp = Integer.to_string(DateTime.to_unix(now))

      signature =
        :hmac
        |> :crypto.mac(:sha256, "mg-signing-key", timestamp <> "token-1")
        |> Base.encode16(case: :lower)

      body = %{
        "signature" => %{"timestamp" => timestamp, "token" => "token-1", "signature" => signature}
      }

      assert :ok = Mailgun.verify(key, body, now)
      assert {:error, :stale_timestamp} = Mailgun.verify(key, body, DateTime.add(now, 600))

      forged = put_in(body, ["signature", "token"], "token-2")
      assert {:error, :bad_signature} = Mailgun.verify(key, forged, now)
      assert {:error, :missing_signature} = Mailgun.verify(key, %{}, now)
    end
  end

  describe "T-40 SendGrid signature" do
    test "T-40: the ECDSA signature covers the timestamp and the raw body" do
      private = :public_key.generate_key({:namedCurve, :secp256r1})
      params = elem(private, 3)
      point = elem(private, 4)

      {:SubjectPublicKeyInfo, der, :not_encrypted} =
        :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {{:ECPoint, point}, params})

      key = Relay.Redacted.wrap(Base.encode64(der))
      body = ~s([{"event":"delivered"}])
      timestamp = "1793700000"
      signature = Base.encode64(:public_key.sign(timestamp <> body, :sha256, private))

      headers = [
        {"x-twilio-email-event-webhook-signature", signature},
        {"x-twilio-email-event-webhook-timestamp", timestamp}
      ]

      opts = [
        header: "x-twilio-email-event-webhook-signature",
        timestamp_header: "x-twilio-email-event-webhook-timestamp"
      ]

      assert :ok = Relay.Channels.verify_ecdsa(key, body, headers, opts)

      assert {:error, :bad_signature} =
               Relay.Channels.verify_ecdsa(key, body <> " ", headers, opts)

      assert {:error, :missing_header} = Relay.Channels.verify_ecdsa(key, body, [], opts)
    end
  end

  describe "CH-47 T-40 SES through SNS and SQS" do
    setup do
      %{cert: der, key: key} =
        :public_key.pkix_test_root_cert(~c"SNS test", key: {:rsa, 2048, 65_537})
      pem = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
      %{key: key, fetch: fn @cert_url -> {:ok, pem} end}
    end

    defp notification(message, key, overrides \\ %{}) do
      fields =
        Map.merge(
          %{
            "Type" => "Notification",
            "MessageId" => "sns-1",
            "TopicArn" => @topic,
            "Message" => Jason.encode!(message),
            "Timestamp" => "2026-11-05T10:00:00.000Z",
            "SignatureVersion" => "2",
            "SigningCertURL" => @cert_url
          },
          overrides
        )

      signature = :public_key.sign(Sns.canonical(fields), :sha256, key)
      Map.put(fields, "Signature", Base.encode64(signature))
    end

    defp bounce(id) do
      %{
        "eventType" => "Bounce",
        "mail" => %{
          "messageId" => "ses-1",
          "tags" => %{"relay_delivery_id" => [Relay.Id.to_string(id)]}
        },
        "bounce" => %{
          "bounceType" => "Permanent",
          "bounceSubType" => "General",
          "timestamp" => "2026-11-05T10:00:00.000Z",
          "bouncedRecipients" => [
            %{
              "emailAddress" => "reader@example.com",
              "action" => "failed",
              "status" => "5.1.1",
              "diagnosticCode" => "smtp; 550 5.1.1 user unknown"
            }
          ]
        }
      }
    end

    test "CH-47, T-40: a signed notification of the account's topic yields its SES events", ctx do
      id = delivery_id()
      body = Jason.encode!(notification(bounce(id), ctx.key))

      assert {:ok, [%Event{type: :bounced, delivery_id: ^id, id: "sns-1"} = event]} =
               Ses.message_events(%{"topic_arn" => @topic}, body, ctx.fetch)

      assert event.code == "Permanent/General"
      {:ok, content} = ChannelDeclarations.compose()
      declarations = ChannelDeclarations.new(content, nil)
      assert %{kind: :hard} = Event.classify(event, declarations, table())
    end

    test "T-40: a tampered message, another topic or a foreign certificate URL is refused", ctx do
      signed = notification(bounce(delivery_id()), ctx.key)
      settings = %{"topic_arn" => @topic}

      tampered = Jason.encode!(%{signed | "Message" => "{}"})
      assert {:error, :bad_signature} = Ses.message_events(settings, tampered, ctx.fetch)

      other = Jason.encode!(signed)
      assert {:error, :wrong_topic} =
               Ses.message_events(%{"topic_arn" => "arn:x"}, other, ctx.fetch)

      for url <- [
            "http://sns.eu-central-1.amazonaws.com/a.pem",
            "https://sns.eu-central-1.amazonaws.com.evil.example/a.pem",
            "https://evil.example/sns.pem"
          ] do
        foreign = Jason.encode!(%{signed | "SigningCertURL" => url})
        assert {:error, :bad_certificate_url} = Ses.message_events(settings, foreign, ctx.fetch)
      end
    end

    test "CH-40: a complaint and a delivery are parsed per recipient" do
      complaint = %{
        "eventType" => "Complaint",
        "mail" => %{"messageId" => "ses-2"},
        "complaint" => %{"complainedRecipients" => [%{"emailAddress" => "a@example.com"}]}
      }

      delivery = %{
        "eventType" => "Delivery",
        "mail" => %{"messageId" => "ses-3"},
        "delivery" => %{"recipients" => ["a@example.com", "b@example.com"]}
      }

      assert [%Event{type: :complained, code: "Complaint"}] = Ses.events(complaint, nil)
      assert [%Event{type: :delivered}, %Event{type: :delivered}] = Ses.events(delivery, nil)
    end
  end
end
