# frozen_string_literal: true

require "time"

module Esuiss
  module Relay
    # X-29
    # API-65
    # Retries a retryable problem or a request that got no answer, waiting for Retry-After when the
    # answer names one and for exponential backoff with full jitter otherwise.
    class RetryPolicy
      # The outcome of one retry decision: retry? with delay_ms, or the reason not to.
      Decision = Struct.new(:retry, :delay_ms, :reason, keyword_init: true) do
        def retry?
          self[:retry]
        end
      end

      attr_reader :max_retries, :base_ms, :cap_ms, :max_retry_after

      def initialize(max_retries: 3, base_ms: 500, cap_ms: 8000, max_retry_after: 60)
        @max_retries = max_retries
        @base_ms = base_ms
        @cap_ms = cap_ms
        @max_retry_after = max_retry_after
      end

      def backoff_ms(retry_number, random)
        (random.rand * [@cap_ms, @base_ms * (2**(retry_number - 1))].min).floor
      end

      def decide(error, retry_number, random, max_retries: @max_retries)
        return refuse("not_retryable") unless retryable?(error)
        return refuse("retries_exhausted") if retry_number > max_retries

        after = error.is_a?(APIError) ? error.retry_after : nil
        return Decision.new(retry: true, delay_ms: backoff_ms(retry_number, random)) if after.nil?
        return refuse("retry_after_too_long") if after > @max_retry_after

        Decision.new(retry: true, delay_ms: after * 1000)
      end

      def self.retry_after(value, now)
        text = value.to_s.strip
        return nil if text.empty?
        return Integer(text, 10) if text.match?(/\A\d+\z/)

        [(Time.httpdate(text) - now).ceil, 0].max
      rescue ArgumentError
        nil
      end

      private

      def retryable?(error)
        error.is_a?(ConnectionError) || (error.is_a?(APIError) && error.retryable?)
      end

      def refuse(reason)
        Decision.new(retry: false, reason: reason)
      end
    end
  end
end
