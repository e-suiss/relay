# frozen_string_literal: true

require "json"
require "openssl"

module Esuiss
  module Relay
    # X-29
    # WH-7
    # Verifies Relay webhooks over the raw body: Ed25519 `v1a` signatures with `whpk_` public keys
    # and HMAC-SHA-256 `v1` signatures with `whsec_` secrets, within a timestamp tolerance.
    class Webhook
      DEFAULT_TOLERANCE = 300
      HEADERS = %w[webhook-id webhook-timestamp webhook-signature].freeze
      SIGNATURE_BYTES = { "v1a" => 64, "v1" => 32 }.freeze

      def initialize(keys, tolerance: DEFAULT_TOLERANCE, clock: -> { Time.now })
        @public_keys = []
        @secrets = []
        Array(keys).each { |key| add_key(key) }
        raise ArgumentError, "at least one webhook key is required" if @public_keys.empty? && @secrets.empty?

        @tolerance = tolerance
        @clock = clock
      end

      def verify(body, headers, now: nil)
        id, timestamp, signature_header = read_headers(headers)
        seconds = parse_timestamp(timestamp)
        tokens = parse_signatures(signature_header)
        current = (now || @clock.call).to_i
        refuse("timestamp_out_of_tolerance") if (current - seconds).abs > @tolerance

        content = "#{id}.#{timestamp}.".b + body.to_s.b
        match = tokens.find { |scheme, signature| valid?(scheme, signature, content) }
        match ? match.first : refuse("no_matching_signature")
      end

      def construct_event(body, headers, now: nil)
        verify(body, headers, now: now)
        JSON.parse(body)
      end

      private

      def refuse(reason)
        raise WebhookVerificationError.new(reason, "webhook verification failed: #{reason}")
      end

      def add_key(key)
        if key.start_with?("whpk_")
          @public_keys << DPoPKey.public_key(Codec.decode_b64(key.delete_prefix("whpk_")))
        elsif key.start_with?("whsec_")
          @secrets << Codec.decode_b64(key.delete_prefix("whsec_"))
        else
          raise ArgumentError, "a webhook key starts with whpk_ or whsec_"
        end
      end

      def read_headers(headers)
        found = {}
        headers.to_h.each do |name, value|
          normalized = name.to_s.downcase.delete_prefix("http_").tr("_", "-")
          next unless HEADERS.include?(normalized) && !value.nil?

          values = Array(value)
          refuse("duplicate_header") if found.key?(normalized) || values.size > 1
          found[normalized] = values.first.to_s
        end
        HEADERS.map { |name| found[name] || refuse("missing_header") }
      end

      def parse_timestamp(timestamp)
        refuse("malformed_header") unless timestamp.match?(/\A(0|[1-9][0-9]*)\z/)
        Integer(timestamp, 10)
      end

      def parse_signatures(header)
        entries = header.split
        refuse("malformed_header") if entries.empty?
        entries.filter_map do |entry|
          scheme, encoded = entry.split(",", 2)
          refuse("malformed_header") if encoded.nil? || encoded.empty?
          next unless SIGNATURE_BYTES.key?(scheme)

          [scheme, decode_signature(scheme, encoded)]
        end
      end

      def decode_signature(scheme, encoded)
        signature = Codec.decode_b64(encoded)
        refuse("malformed_header") unless signature.bytesize == SIGNATURE_BYTES.fetch(scheme)
        signature
      rescue ArgumentError
        refuse("malformed_header")
      end

      def valid?(scheme, signature, content)
        if scheme == "v1a"
          @public_keys.any? { |key| ed25519?(key, signature, content) }
        else
          @secrets.any? { |secret| OpenSSL.secure_compare(OpenSSL::HMAC.digest("SHA256", secret, content), signature) }
        end
      end

      def ed25519?(key, signature, content)
        key.verify(nil, signature, content)
      rescue OpenSSL::PKey::PKeyError
        false
      end
    end
  end
end
