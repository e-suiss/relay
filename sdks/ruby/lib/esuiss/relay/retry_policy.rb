# frozen_string_literal: true

require "time"

module Esuiss
  module Relay
    # X-29
    # API-65
    # Retries only problems marked retryable, after max(Retry-After, full jitter).
    class RetryPolicy
      attr_reader :base_delay, :max_delay, :max_retry_after

      def initialize(base_delay: 0.5, max_delay: 8.0, max_retry_after: 60)
        @base_delay = base_delay
        @max_delay = max_delay
        @max_retry_after = max_retry_after
      end

      def ceiling(retry_index)
        [@max_delay, @base_delay * (2**retry_index)].min
      end

      def delay(error, retry_index, random)
        return nil unless error.is_a?(APIError) && error.retryable?

        retry_after = error.retry_after
        return nil if retry_after && retry_after > @max_retry_after

        jitter = random.rand * ceiling(retry_index)
        [retry_after || 0, jitter].max
      end

      def self.retry_after(value, now)
        text = value.to_s.strip
        return nil if text.empty?
        return Integer(text, 10) if text.match?(/\A\d+\z/)

        [(Time.httpdate(text) - now).ceil, 0].max
      rescue ArgumentError
        nil
      end
    end
  end
end
