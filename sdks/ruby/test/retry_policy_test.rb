# frozen_string_literal: true

require "test_helper"

class RetryPolicyTest < Minitest::Test
  def error(retryable:, retry_after: nil)
    Esuiss::Relay::ServerError.new(status: 503, problem: { "code" => "service_unavailable", "retryable" => retryable },
                                   retry_after: retry_after)
  end

  def test_x29_full_jitter_stays_within_the_exponential_ceiling
    policy = Esuiss::Relay::RetryPolicy.new

    [0, 1, 2, 3, 4, 5].each do |index|
      ceiling = [8.0, 0.5 * (2**index)].min

      assert_in_delta 0.0, policy.delay(error(retryable: true), index, TestSupport::FixedRandom.new(0.0))
      assert_operator policy.delay(error(retryable: true), index, TestSupport::FixedRandom.new(0.999_999)), :<=, ceiling
    end
  end

  def test_x29_retry_after_is_a_lower_bound_and_has_a_ceiling
    policy = Esuiss::Relay::RetryPolicy.new

    assert_equal 5, policy.delay(error(retryable: true, retry_after: 5), 0, TestSupport::FixedRandom.new(0.9))
    assert_nil policy.delay(error(retryable: true, retry_after: 61), 0, TestSupport::FixedRandom.new(0.9))
    assert_nil policy.delay(error(retryable: false), 0, TestSupport::FixedRandom.new(0.9))
  end

  def test_x29_retry_after_header_forms
    now = Time.at(1_800_000_000)

    assert_equal 12, Esuiss::Relay::RetryPolicy.retry_after("12", now)
    assert_equal 30, Esuiss::Relay::RetryPolicy.retry_after((now + 30).httpdate, now)
    assert_equal 0, Esuiss::Relay::RetryPolicy.retry_after((now - 30).httpdate, now)
    assert_nil Esuiss::Relay::RetryPolicy.retry_after("soon", now)
    assert_nil Esuiss::Relay::RetryPolicy.retry_after(nil, now)
  end
end
