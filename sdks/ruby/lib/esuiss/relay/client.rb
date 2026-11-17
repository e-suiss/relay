# frozen_string_literal: true

require "json"
require "securerandom"

module Esuiss
  module Relay
    # X-29
    # API-10
    # API-55
    # The Relay server API client. Every operation of the contract is a method; requests carry the
    # pinned Relay-Version, a DPoP-bound Access token, and an Idempotency-Key that stays the same on
    # every retry of a call.
    class Client
      include Generated::Operations
      include Agents

      attr_reader :base_url, :max_retries, :timeout

      def initialize(base_url:, auth:, max_retries: 3, timeout: 30, transport: NetHTTPTransport.new,
                     retry_policy: RetryPolicy.new, random: Random.new, sleeper: ->(seconds) { sleep(seconds) },
                     clock: -> { Time.now }, monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     idempotency_keys: -> { SecureRandom.uuid })
        @base_url = base_url.chomp("/")
        @auth = auth
        @max_retries = max_retries
        @timeout = timeout
        @transport = transport
        @retry_policy = retry_policy
        @random = random
        @sleeper = sleeper
        @clock = clock
        @monotonic = monotonic
        @idempotency_keys = idempotency_keys
      end

      def request(method:, path:, query: {}, headers: {}, body: nil, content_type: "application/json",
                  idempotent: false, idempotency_key: nil, request_options: {})
        request_headers = default_headers.merge(compact(headers)).merge(request_options.fetch(:headers, {}))
        payload = body.nil? ? nil : JSON.generate(body)
        request_headers["Content-Type"] = content_type if payload
        if idempotent
          request_headers["Idempotency-Key"] =
            idempotency_key || request_options[:idempotency_key] || @idempotency_keys.call
        end
        execute(method.to_s.upcase, url_for(path, query), request_headers, payload, request_options)
      end

      def inspect
        "#<#{self.class.name} base_url=#{@base_url.inspect}>"
      end

      private

      def perform(method:, path:, query:, headers:, body:, idempotent:, response:, request_options:,
                  content_type: "application/json", idempotency_key: nil)
        answer = request(method: method, path: path, query: query, headers: headers, body: body,
                         content_type: content_type, idempotent: idempotent,
                         idempotency_key: idempotency_key, request_options: request_options)
        decode(answer, response)
      end

      def paginate(method:, path:, query:, headers:, request_options:)
        raw = perform(method: method, path: path, query: query, headers: headers, body: nil,
                      idempotent: false, response: :json, request_options: request_options)
        Page.new(raw) do |cursor|
          following = query.merge("starting_after" => cursor, "ending_before" => nil)
          paginate(method: method, path: path, query: following, headers: headers,
                   request_options: request_options)
        end
      end

      def execute(method, url, headers, payload, options)
        retries = 0
        renewed = false
        max = options.fetch(:max_retries, @max_retries)
        loop do
          response = @transport.call(Request.new(method: method, url: url, headers: headers.merge(authorization(method, url)),
                                                 body: payload, timeout: options.fetch(:timeout, @timeout)))
          return response if response.status.between?(200, 299)

          error = Errors.from_response(response,
                                       retry_after: RetryPolicy.retry_after(response.header("retry-after"), @clock.call))
          if error.code == "auth_expired_token" && !renewed && @auth
            renewed = true
            @auth.invalidate
            next
          end
          delay = retries < max ? @retry_policy.delay(error, retries, @random) : nil
          raise error if delay.nil?

          @sleeper.call(delay)
          retries += 1
        end
      end

      def authorization(method, url)
        @auth ? @auth.authorize(method, url) : {}
      end

      def default_headers
        {
          "Accept" => "application/json",
          "Relay-Version" => Generated::API_VERSION,
          "User-Agent" => "esuiss-relay-ruby/#{VERSION}"
        }
      end

      def decode(response, kind)
        case kind
        when :json then response.body.empty? ? nil : JSON.parse(response.body)
        when :text then response.body.dup.force_encoding(::Encoding::UTF_8)
        end
      end

      def url_for(path, query)
        params = compact(query)
        params.empty? ? "#{@base_url}#{path}" : "#{@base_url}#{path}?#{URI.encode_www_form(params)}"
      end

      def compact(hash)
        hash.reject { |_, value| value.nil? }
      end

      def segment(value)
        value.to_s.b.gsub(/[^A-Za-z0-9\-._~]/n) { |char| format("%%%02X", char.ord) }
      end

      def csv(value)
        value.nil? ? nil : Array(value).join(",")
      end
    end
  end
end
