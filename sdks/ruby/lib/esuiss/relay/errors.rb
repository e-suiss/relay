# frozen_string_literal: true

require "json"

module Esuiss
  module Relay
    # Base class of every error the SDK raises.
    class RelayError < StandardError; end

    # X-29
    # An RFC 9457 problem answered by Relay, with its status, code and retry hint.
    class APIError < RelayError
      attr_reader :status, :code, :title, :detail, :type, :request_id, :retry_after, :problem,
                  :headers

      def initialize(status:, problem: {}, headers: {}, retry_after: nil)
        @status = status
        @problem = problem
        @headers = headers
        @code = problem["code"]
        @title = problem["title"]
        @detail = problem["detail"]
        @type = problem["type"]
        @retryable = problem["retryable"] == true
        @request_id = problem["request_id"] || headers["request-id"]
        @retry_after = retry_after
        super("#{status} #{@code || 'error'}: #{@detail || @title || 'Relay answered with an error'}")
      end

      def retryable?
        @retryable
      end
    end

    # The credentials are missing, invalid, expired or lack a scope (error family auth).
    class AuthenticationError < APIError; end

    # The request was refused as it stands (a 4xx outside the other classes).
    class ValidationError < APIError; end

    # The resource does not exist in this tenant and environment.
    class NotFoundError < APIError; end

    # The resource changed or conflicts with the request (409, 412, 428).
    class ConflictError < APIError; end

    # A rate limit or quota was reached (error family quota, or 429).
    class RateLimitError < APIError; end

    # The Idempotency-Key was missing, invalid, reused or is still in progress.
    class IdempotencyError < APIError; end

    # Relay failed or is unavailable (5xx).
    class ServerError < APIError; end

    # Relay could not be reached or did not answer in time.
    class ConnectionError < RelayError; end

    # The Access token could not be obtained.
    class TokenError < RelayError; end

    # A webhook request failed signature or timestamp verification.
    class WebhookVerificationError < RelayError; end

    # A wait helper ran past its timeout.
    class WaitTimeoutError < RelayError; end

    # X-29
    # Maps answers of Relay to the error classes.
    module Errors
      module_function

      def from_response(response, retry_after: nil)
        problem = parse(response.body)
        klass = classify(problem["code"], response.status)
        klass.new(status: response.status, problem: problem, headers: response.headers,
                  retry_after: retry_after || non_negative(problem["retry_after"]))
      end

      def classify(code, status)
        family = Generated::ERROR_CODES.dig(code, :family)
        by_family(family) || by_status(status, family)
      end

      def by_family(family)
        case family
        when "idempotency" then IdempotencyError
        when "auth" then AuthenticationError
        when "quota" then RateLimitError
        end
      end

      def by_status(status, family)
        if status >= 500 then ServerError
        elsif status == 429 then RateLimitError
        elsif family.nil? && [401, 403].include?(status) then AuthenticationError
        elsif status == 404 then NotFoundError
        elsif [409, 412, 428].include?(status) then ConflictError
        else ValidationError
        end
      end

      def parse(body)
        parsed = body.nil? || body.empty? ? {} : JSON.parse(body)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      def non_negative(value)
        value.is_a?(Integer) && value >= 0 ? value : nil
      end
    end
  end
end
