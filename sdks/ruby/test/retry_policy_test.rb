# frozen_string_literal: true

require "test_helper"

class RetryPolicyTest < Minitest::Test
  def error(retryable:, retry_after: nil)
    Esuiss::Relay::ServerError.new(status: 503, problem: { "code" => "service_unavailable", "retryable" => retryable },
                                   retry_after: retry_after)
  end

  def random(value)
    TestSupport::FixedRandom.new(value)
  end

  def test_x29_full_jitter_stays_within_the_exponential_ceiling
    policy = Esuiss::Relay::RetryPolicy.new

    (1..6).each do |retry_number|
      ceiling = [8000, 500 * (2**(retry_number - 1))].min

      assert_equal 0, policy.backoff_ms(retry_number, random(0.0))
      assert_operator policy.backoff_ms(retry_number, random(0.999_999)), :<, ceiling
    end
  end

  def test_x29_retry_after_is_waited_exactly_and_has_a_ceiling
    policy = Esuiss::Relay::RetryPolicy.new

    assert_equal 5000, policy.decide(error(retryable: true, retry_after: 5), 1, random(0.9)).delay_ms
    assert_equal "retry_after_too_long", policy.decide(error(retryable: true, retry_after: 61), 1, random(0.9)).reason
    assert_equal "not_retryable", policy.decide(error(retryable: false), 1, random(0.9)).reason
    assert_equal "retries_exhausted", policy.decide(error(retryable: true), 4, random(0.9)).reason
  end

  def test_x29_network_errors_are_retried_with_backoff
    decision = Esuiss::Relay::RetryPolicy.new.decide(Esuiss::Relay::ConnectionError.new("down"), 2, random(0.5))

    assert_predicate decision, :retry?
    assert_equal 500, decision.delay_ms
  end

  def test_x29_retry_after_header_forms
    now = Time.at(1_800_000_000)

    assert_equal 12, Esuiss::Relay::RetryPolicy.retry_after("12", now)
    assert_equal 30, Esuiss::Relay::RetryPolicy.retry_after((now + 30).httpdate, now)
    assert_equal 0, Esuiss::Relay::RetryPolicy.retry_after((now - 30).httpdate, now)
    assert_nil Esuiss::Relay::RetryPolicy.retry_after("-3", now)
    assert_nil Esuiss::Relay::RetryPolicy.retry_after("soon", now)
    assert_nil Esuiss::Relay::RetryPolicy.retry_after(nil, now)
  end
end
