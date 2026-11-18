# frozen_string_literal: true

require "json"

module Esuiss
  module Relay
    # Base class of every error the SDK raises.
    class RelayError < StandardError; end

    # X-29
    # An error answer of Relay, with its status, the RFC 9457 problem when there is one, and its
    # retry hint.
    class APIError < RelayError
      attr_reader :status, :code, :title, :detail, :type, :request_id, :retry_after, :problem,
                  :headers

      def initialize(status:, problem: {}, headers: {}, retry_after: nil, retryable: nil)
        @status = status
        @problem = problem
        @headers = headers
        @code = problem["code"]
        @title = problem["title"]
        @detail = problem["detail"]
        @type = problem["type"]
        @retryable = retryable.nil? ? problem["retryable"] == true : retryable
        @request_id = problem["request_id"] || headers["request-id"]
        @retry_after = retry_after
        super("#{status} #{@code || 'error'}: #{@detail || @title || 'Relay answered with an error'}")
      end

      def retryable?
        @retryable
      end

      def field_errors
        Array(@problem["errors"])
      end
    end

    # The credentials are missing, invalid, expired or lack a scope (error family auth).
    class AuthenticationError < APIError; end

    # The request was refused as it stands.
    class ValidationError < APIError; end

    # The resource does not exist in this tenant and environment.
    class NotFoundError < ValidationError; end

    # The resource changed or conflicts with the request (409, 412, 428).
    class ConflictError < ValidationError; end

    # A rate limit or quota was reached (error family quota, or 429).
    class RateLimitError < APIError; end

    # The Idempotency-Key was missing, invalid, reused or is still in progress.
    class IdempotencyError < APIError; end

    # Relay failed or is unavailable.
    class ServerError < APIError; end

    # Relay could not be reached or did not answer in time.
    class ConnectionError < RelayError; end

    # The Access token could not be obtained.
    class TokenError < RelayError; end

    # A webhook request failed verification; `reason` is missing_header, duplicate_header,
    # malformed_header, timestamp_out_of_tolerance or no_matching_signature.
    class WebhookVerificationError < RelayError
      attr_reader :reason

      def initialize(reason, message = reason)
        @reason = reason
        super(message)
      end
    end

    # A wait helper ran past its timeout.
    class WaitTimeoutError < RelayError; end

    # X-29
    # Maps answers of Relay to the error classes.
    module Errors
      FAMILY_CLASSES = { "auth" => "auth", "quota" => "rate_limit", "idempotency" => "idempotency",
                         "platform" => "server" }.freeze

      module_function

      def from_response(response, retry_after: nil)
        problem = parse(response.body)
        code = problem["code"]
        klass = error_class(classify(code, response.status), response.status)
        retryable = problem["retryable"]
        retryable = default_retryable(response.status, code) unless [true, false].include?(retryable)
        klass.new(status: response.status, problem: problem, headers: response.headers, retryable: retryable,
                  retry_after: retry_after || non_negative(problem["retry_after"]))
      end

      def classify(code, status)
        family = Generated::ERROR_CODES.dig(code, :family)
        return FAMILY_CLASSES.fetch(family) { status >= 500 ? "server" : "validation" } if family

        if [401, 403].include?(status) then "auth"
        elsif status == 429 then "rate_limit"
        elsif status >= 500 then "server"
        else "validation"
        end
      end

      def error_class(name, status)
        case name
        when "auth" then AuthenticationError
        when "rate_limit" then RateLimitError
        when "idempotency" then IdempotencyError
        when "server" then ServerError
        else validation_class(status)
        end
      end

      def validation_class(status)
        if status == 404 then NotFoundError
        elsif [409, 412, 428].include?(status) then ConflictError
        else ValidationError
        end
      end

      def default_retryable(status, code)
        rows = Generated::RETRYABLE_DEFAULTS.select { |row| row[:status] == status }
        row = rows.find { |r| r[:code] && r[:code] == code } || rows.find { |r| r[:code].nil? }
        row ? row[:retryable] : false
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
