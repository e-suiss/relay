# frozen_string_literal: true

require "test_helper"

class ConformanceSdkTest < Minitest::Test
  include TestSupport

  DIR = TestSupport.repo_path("conformance", "sdk", "vectors", "1")
  SIGNATURES = TestSupport.json_fixture("conformance", "webhooks", "vectors", "1", "signature.json")
  CLASSES = {
    "auth" => Esuiss::Relay::AuthenticationError, "validation" => Esuiss::Relay::ValidationError,
    "rate_limit" => Esuiss::Relay::RateLimitError, "idempotency" => Esuiss::Relay::IdempotencyError,
    "server" => Esuiss::Relay::ServerError
  }.freeze

  def vector(name)
    path = File.join(DIR, "#{name}.json")
    skip "conformance/sdk/vectors/1/#{name}.json is not present" unless File.exist?(path)
    JSON.parse(File.read(path))
  end

  def response(spec)
    body = spec["body"]
    text = body.nil? || body.is_a?(String) ? body.to_s : JSON.generate(body)
    Esuiss::Relay::Response.new(status: spec.fetch("status"), headers: spec.fetch("headers", {}), body: text)
  end

  def error_for(spec, now = Time.now)
    answer = response(spec)
    retry_after = Esuiss::Relay::RetryPolicy.retry_after(answer.header("retry-after"), now)
    Esuiss::Relay::Errors.from_response(answer, retry_after: retry_after)
  end

  def test_x29_errors_classify_like_the_vectors
    data = vector("errors")
    data.fetch("cases").each do |entry|
      error = error_for(entry.fetch("response"))
      expect = entry.fetch("expect")

      assert_kind_of CLASSES.fetch(expect.fetch("class")), error, entry.fetch("name")
      assert_equal expect.fetch("retryable"), error.retryable?, entry.fetch("name")
      assert_equal expect.fetch("status"), error.status
      assert_equal expect["code"].to_s, error.code.to_s
      assert_equal expect["request_id"], error.request_id if expect.key?("request_id")
      assert_equal expect["field_errors"], error.field_errors.size if expect.key?("field_errors")
      assert_equal expect["retry_after_s"], error.retry_after if expect.key?("retry_after_s")
    end
  end

  def test_x29_catalog_classes_match_the_vectors
    vector("errors").fetch("catalog").each do |entry|
      assert_equal entry.fetch("class"), Esuiss::Relay::Errors.classify(entry.fetch("code"), entry.fetch("status")),
                   entry.fetch("code")
    end
  end

  def test_x29_retry_backoff_matches_the_vectors
    data = vector("retry")
    policy = Esuiss::Relay::RetryPolicy.new
    data.fetch("backoff").each do |row|
      delay = policy.backoff_ms(row.fetch("retry"), FixedRandom.new(row.fetch("random")))

      assert_equal row.fetch("delay_ms"), delay
      assert_operator delay, :<=, row.fetch("max_ms")
    end
  end

  def test_x29_retry_decisions_match_the_vectors
    policy = Esuiss::Relay::RetryPolicy.new
    vector("retry").fetch("decisions").each do |entry|
      now = Time.iso8601(entry.fetch("now"))
      error = entry["network_error"] ? Esuiss::Relay::ConnectionError.new("down") : error_for(entry["response"], now)
      decision = policy.decide(error, entry.fetch("retry"), FixedRandom.new(entry.fetch("random")))
      expect = entry.fetch("expect")

      assert_equal expect.fetch("retry"), decision.retry?, entry.fetch("name")
      if expect.fetch("retry")
        assert_equal expect.fetch("delay_ms"), decision.delay_ms, entry.fetch("name")
      else
        assert_equal expect.fetch("reason"), decision.reason, entry.fetch("name")
      end
    end
  end

  def test_x29_idempotency_keys_follow_the_vectors
    vector("idempotency").fetch("cases").each do |entry|
      keys = entry.fetch("calls").map { |call| run_idempotency_call(entry.fetch("name"), call) }
      assert_equal keys.size, keys.compact.uniq.size if entry["distinct_keys_across_calls"]
    end
  end

  def run_idempotency_call(name, call)
    stubs = call.fetch("responses").map do |r|
      r["network_error"] ? Esuiss::Relay::ConnectionError.new("down") : response(r)
    end
    transport = StubTransport.new(*stubs)
    client, = TestSupport.client(transport)
    expect = call.fetch("expect")
    outcome = begin
      client.request(method: call.fetch("method"), path: call.fetch("path"),
                     idempotent: call.fetch("takes_idempotency_key"), idempotency_key: call["caller_idempotency"],
                     body: call.fetch("method") == "GET" ? nil : {})
    rescue Esuiss::Relay::APIError => e
      e
    end
    check_idempotency(name, expect, transport.requests.map { |r| r.headers["Idempotency-Key"] }, outcome)
  end

  def check_idempotency(name, expect, keys, outcome)
    assert_equal expect.fetch("requests"), keys.size, name
    assert_equal expect.fetch("key_sent"), !keys.first.nil?, name
    assert_equal 1, keys.uniq.size, name if expect["same_key_on_every_request"]
    assert_operator keys.first.to_s.length, :>=, 8 if expect.fetch("key_sent")
    assert_equal expect["sent_idempotency"], keys.first, name if expect.key?("sent_idempotency")
    if expect.fetch("outcome") == "success"
      assert_instance_of Esuiss::Relay::Response, outcome, name
      assert_equal expect.fetch("replayed"), outcome.replayed?, name
    else
      assert_kind_of CLASSES.fetch(expect.fetch("error_class")), outcome, name
      assert_equal expect.fetch("error_code"), outcome.code
    end
    keys.first
  end

  def test_api56_pagination_follows_the_vectors
    vector("pagination").fetch("cases").each do |entry|
      exchanges = entry.fetch("exchanges")
      transport = StubTransport.new(*exchanges.map { |x| TestSupport.json(200, x.fetch("page")) })
      client, = TestSupport.client(transport)
      params = entry.fetch("params").transform_keys(&:to_sym)
      items = client.list_notifications(**params).lazy.map { |item| item["id"] }
      items = entry.key?("take") ? items.first(entry["take"]) : items.to_a
      queries = transport.requests.map { |r| URI.decode_www_form(URI(r.url).query.to_s).to_h }

      assert_equal entry.dig("expect", "items"), items, entry.fetch("name")
      assert_equal entry.dig("expect", "requests"), transport.requests.size, entry.fetch("name")
      assert_equal exchanges.first(queries.size).map { |x| x.fetch("query") }, queries, entry.fetch("name")
    end
  end

  def test_api56_both_cursors_are_refused_before_any_request
    vector("pagination").fetch("rejections").each do |entry|
      transport = StubTransport.new
      client, = TestSupport.client(transport)
      params = entry.fetch("params").transform_keys(&:to_sym)
      error = assert_raises(ArgumentError) { client.list_notifications(**params) }

      assert_includes error.message, entry.dig("expect", "error")
      assert_empty transport.requests
    end
  end

  def test_wh7_webhook_header_handling_follows_the_vectors
    cases = SIGNATURES.fetch("cases").to_h { |c| [c.fetch("name"), c] }
    vector("webhooks").fetch("cases").each do |entry|
      base = cases.fetch(entry.fetch("base"))
      verifier = Esuiss::Relay::Webhook.new(entry.fetch("keys").map { |k| SIGNATURES.dig("keys", k) })
      body = [entry.fetch("body_hex", base.fetch("body_hex"))].pack("H*")
      outcome = begin
        verifier.verify(body, webhook_headers(base, entry.fetch("headers")),
                        now: entry.fetch("now", base.fetch("webhook_timestamp")))
      rescue Esuiss::Relay::WebhookVerificationError => e
        e
      end
      check_webhook(entry, outcome)
    end
  end

  def webhook_headers(base, overrides)
    headers = { "webhook-id" => base.fetch("webhook_id"), "webhook-timestamp" => base.fetch("webhook_timestamp").to_s,
                "webhook-signature" => "#{base.fetch('v1a')} #{base.fetch('v1')}" }
    overrides.each do |name, value|
      headers.delete_if { |existing, _| existing.casecmp?(name) }
      headers[name] = value.gsub("{v1a}", base.fetch("v1a")).gsub("{v1}", base.fetch("v1")) unless value.nil?
    end
    headers
  end

  def check_webhook(entry, outcome)
    expect = entry.fetch("expect")
    if expect.fetch("ok")
      assert_equal expect.fetch("scheme"), outcome, entry.fetch("name")
    else
      assert_kind_of Esuiss::Relay::WebhookVerificationError, outcome, entry.fetch("name")
      assert_equal expect.fetch("error"), outcome.reason, entry.fetch("name")
    end
  end
end
