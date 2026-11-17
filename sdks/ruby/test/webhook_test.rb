# frozen_string_literal: true

require "test_helper"

class WebhookTest < Minitest::Test
  VECTOR = TestSupport.json_fixture("conformance", "webhooks", "vectors", "1", "signature.json")
  KEYS = VECTOR.fetch("keys")
  CASES = VECTOR.fetch("cases").to_h { |c| [c.fetch("name"), c] }

  def webhook(*keys)
    Esuiss::Relay::Webhook.new(keys, tolerance: VECTOR.fetch("tolerance_s"))
  end

  def headers(entry, signature)
    { "Webhook-Id" => entry.fetch("webhook_id"), "Webhook-Timestamp" => entry.fetch("webhook_timestamp").to_s,
      "Webhook-Signature" => signature }
  end

  def body(entry)
    [entry.fetch("body_hex")].pack("H*")
  end

  def test_wh7_every_vector_case_verifies_with_v1a_and_v1
    both = webhook(KEYS.fetch("ed25519_public_key"), KEYS.fetch("hmac_secret"))
    CASES.each_value do |entry|
      now = entry.fetch("webhook_timestamp")
      combined = "#{entry.fetch('v1a')} #{entry.fetch('v1')}"

      assert both.verify(body(entry), headers(entry, combined), now: now), entry.fetch("name")
      assert webhook(KEYS.fetch("ed25519_public_key")).verify(body(entry), headers(entry, entry.fetch("v1a")), now: now)
      assert webhook(KEYS.fetch("hmac_secret")).verify(body(entry), headers(entry, entry.fetch("v1")), now: now)
    end
  end

  def test_wh7_signed_content_matches_vector
    CASES.each_value do |entry|
      content = "#{entry.fetch('webhook_id')}.#{entry.fetch('webhook_timestamp')}.".b + body(entry)

      assert_equal entry.fetch("signed_content_hex"), content.unpack1("H*")
    end
  end

  def test_wh7_vector_rejections_fail
    verifier = webhook(KEYS.fetch("ed25519_public_key"), KEYS.fetch("hmac_secret"))
    VECTOR.fetch("rejections").each do |rejection|
      entry = CASES.fetch(rejection.fetch("case"))
      payload = rejection.key?("body_hex") ? [rejection.fetch("body_hex")].pack("H*") : body(entry)
      signature = if rejection["swap_versions"]
                    "v1a,#{entry.fetch('v1').split(',', 2).last} v1,#{entry.fetch('v1a').split(',', 2).last}"
                  else
                    "#{entry.fetch('v1a')} #{entry.fetch('v1')}"
                  end
      sent = headers(entry, signature)
      sent["Webhook-Id"] = rejection.fetch("webhook_id") if rejection.key?("webhook_id")
      now = rejection.fetch("now", entry.fetch("webhook_timestamp"))

      assert_raises(Esuiss::Relay::WebhookVerificationError, rejection.fetch("name")) do
        verifier.verify(payload, sent, now: now)
      end
    end
  end

  def test_wh7_missing_headers_and_rack_style_headers
    entry = CASES.fetch("standard-webhooks-reference-body")
    verifier = webhook(KEYS.fetch("hmac_secret"))
    rack = { "HTTP_WEBHOOK_ID" => entry.fetch("webhook_id"),
             "HTTP_WEBHOOK_TIMESTAMP" => entry.fetch("webhook_timestamp").to_s,
             "HTTP_WEBHOOK_SIGNATURE" => entry.fetch("v1") }

    assert verifier.verify(body(entry), rack, now: entry.fetch("webhook_timestamp"))
    assert_raises(Esuiss::Relay::WebhookVerificationError) do
      verifier.verify(body(entry), { "webhook-id" => "x" }, now: entry.fetch("webhook_timestamp"))
    end
  end

  def test_wh7_construct_event_parses_after_verification
    entry = CASES.fetch("cloudevent-account-created")
    event = webhook(KEYS.fetch("ed25519_public_key"))
            .construct_event(body(entry), headers(entry, entry.fetch("v1a")), now: entry.fetch("webhook_timestamp"))

    assert_equal "evt_2a8nW3zQ0jVb7lq9b8cXUg", event.fetch("id")
  end

  def test_wh7_rejects_unknown_key_kinds
    assert_raises(ArgumentError) { Esuiss::Relay::Webhook.new(["secret"]) }
  end
end
