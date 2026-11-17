# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  include TestSupport

  ACCEPTED = { "object" => "event_accepted", "id" => "evt_1" }.freeze

  def test_x29_idempotency_key_is_generated_and_reused_across_retries
    transport = StubTransport.new(TestSupport.problem(503, "service_unavailable", retryable: true),
                                  TestSupport.problem(500, "internal_error", retryable: true),
                                  TestSupport.json(202, ACCEPTED))
    client, sleeps = TestSupport.client(transport)

    assert_equal ACCEPTED, client.create_event({ "workflow" => "welcome" })
    keys = transport.requests.map { |r| r.headers["Idempotency-Key"] }

    assert_equal 3, keys.size
    assert_equal 1, keys.uniq.size
    assert_match(/\A\h{8}-\h{4}-4\h{3}-\h{4}-\h{12}\z/, keys.first)
    assert_equal 2, sleeps.size
  end

  def test_x29_caller_idempotency_key_wins
    transport = StubTransport.new(TestSupport.json(202, ACCEPTED))
    client, = TestSupport.client(transport)
    client.create_event({ "workflow" => "welcome" }, idempotency_key: "caller-key-1")

    assert_equal "caller-key-1", transport.requests.first.headers["Idempotency-Key"]
  end

  def test_x29_fresh_dpop_proof_on_every_attempt
    transport = StubTransport.new(TestSupport.problem(503, "service_unavailable", retryable: true),
                                  TestSupport.json(202, ACCEPTED))
    client, = TestSupport.client(transport)
    client.create_event({ "workflow" => "welcome" })

    assert_equal(%w[proof-1 proof-2], transport.requests.map { |r| r.headers["DPoP"] })
  end

  def test_x29_non_retryable_problem_is_raised_at_once
    transport = StubTransport.new(TestSupport.problem(422, "validation_failed", retryable: false))
    client, sleeps = TestSupport.client(transport)

    error = assert_raises(Esuiss::Relay::ValidationError) { client.create_event({ "workflow" => "welcome" }) }
    assert_equal "validation_failed", error.code
    refute_predicate error, :retryable?
    assert_empty sleeps
    assert_equal 1, transport.requests.size
  end

  def test_x29_retries_stop_after_max_retries
    responses = Array.new(4) { TestSupport.problem(503, "service_unavailable", retryable: true) }
    transport = StubTransport.new(*responses)
    client, sleeps = TestSupport.client(transport)

    assert_raises(Esuiss::Relay::ServerError) { client.create_event({ "workflow" => "welcome" }) }
    assert_equal 4, transport.requests.size
    assert_equal 3, sleeps.size
  end

  def test_x29_retry_after_header_sets_the_minimum_delay
    limited = Esuiss::Relay::Response.new(status: 429, headers: { "Retry-After" => "7" },
                                          body: JSON.generate({ "code" => "rate_limited", "retryable" => true }))
    transport = StubTransport.new(limited, TestSupport.json(202, ACCEPTED))
    client, sleeps = TestSupport.client(transport)
    client.create_event({ "workflow" => "welcome" })

    assert_equal [7], sleeps
  end

  def test_x29_retry_after_above_the_ceiling_is_not_waited_for
    limited = Esuiss::Relay::Response.new(status: 429, headers: { "Retry-After" => "3600" },
                                          body: JSON.generate({ "code" => "rate_limited", "retryable" => true }))
    client, sleeps = TestSupport.client(StubTransport.new(limited))

    assert_raises(Esuiss::Relay::RateLimitError) { client.create_event({ "workflow" => "welcome" }) }
    assert_empty sleeps
  end

  def test_x29_expired_token_is_renewed_once_without_counting_a_retry
    auth = StubAuth.new
    transport = StubTransport.new(TestSupport.problem(401, "auth_expired_token", retryable: false),
                                  TestSupport.json(200, { "object" => "notification", "id" => "ntf_1" }))
    client, sleeps = TestSupport.client(transport, auth: auth)
    client.get_notification("ntf_1")

    assert_equal 1, auth.invalidations
    assert_empty sleeps
  end

  def test_api55_every_request_pins_the_api_version
    transport = StubTransport.new(TestSupport.json(200, { "id" => "ntf_1" }))
    client, = TestSupport.client(transport)
    client.get_notification("ntf_1")
    request = transport.requests.first

    assert_equal Esuiss::Relay::API_VERSION, request.headers["Relay-Version"]
    assert_equal "GET", request.http_method
    assert_equal "https://relay.test/v1/notifications/ntf_1", request.url
    assert_nil request.headers["Idempotency-Key"]
    assert_nil request.body
    assert_equal "esuiss-relay-ruby/#{Esuiss::Relay::VERSION}", request.headers["User-Agent"]
  end

  def test_x29_path_segments_are_escaped_and_query_compacted
    transport = StubTransport.new(TestSupport.json(200, { "id" => "ntf_1" }))
    client, = TestSupport.client(transport)
    client.get_notification("a b/c")

    assert_equal "https://relay.test/v1/notifications/a%20b%2Fc", transport.requests.first.url
  end

  def test_x29_transport_errors_are_raised_as_connection_errors
    transport = StubTransport.new(Esuiss::Relay::ConnectionError.new("down"))
    client, sleeps = TestSupport.client(transport)

    assert_raises(Esuiss::Relay::ConnectionError) { client.get_notification("ntf_1") }
    assert_empty sleeps
  end

  def test_x29_request_options_override_retries_and_headers
    transport = StubTransport.new(TestSupport.problem(503, "service_unavailable", retryable: true))
    client, = TestSupport.client(transport)

    assert_raises(Esuiss::Relay::ServerError) do
      client.get_notification("ntf_1", request_options: { max_retries: 0, headers: { "X-Trace" => "1" } })
    end
    assert_equal "1", transport.requests.first.headers["X-Trace"]
  end
end
