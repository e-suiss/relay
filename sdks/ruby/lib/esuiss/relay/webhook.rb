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

      def initialize(keys, tolerance: DEFAULT_TOLERANCE, clock: -> { Time.now })
        @public_keys = []
        @secrets = []
        Array(keys).each { |key| add_key(key) }
        raise ArgumentError, "at least one webhook key is required" if @public_keys.empty? && @secrets.empty?

        @tolerance = tolerance
        @clock = clock
      end

      def verify(body, headers, now: nil)
        id, timestamp, signatures = read_headers(headers)
        seconds = parse_timestamp(timestamp)
        current = (now || @clock.call).to_i
        if (current - seconds).abs > @tolerance
          raise WebhookVerificationError, "webhook-timestamp is outside the tolerance"
        end

        content = "#{id}.#{timestamp}.".b + body.to_s.b
        return true if signatures.split.any? { |entry| valid?(entry, content) }

        raise WebhookVerificationError, "no webhook signature matches"
      end

      def construct_event(body, headers, now: nil)
        verify(body, headers, now: now)
        JSON.parse(body)
      end

      private

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
        normalized = headers.to_h do |name, value|
          [name.to_s.downcase.delete_prefix("http_").tr("_", "-"), Array(value).first.to_s]
        end
        values = %w[webhook-id webhook-timestamp webhook-signature].map { |name| normalized[name] }
        raise WebhookVerificationError, "webhook headers are missing" if values.any? { |v| v.nil? || v.empty? }

        values
      end

      def parse_timestamp(timestamp)
        Integer(timestamp, 10)
      rescue ArgumentError
        raise WebhookVerificationError, "webhook-timestamp is not a number"
      end

      def valid?(entry, content)
        version, encoded = entry.split(",", 2)
        return false if encoded.nil?

        signature = Codec.decode_b64(encoded)
        case version
        when "v1a" then @public_keys.any? { |key| ed25519?(key, signature, content) }
        when "v1" then @secrets.any? { |secret| hmac?(secret, signature, content) }
        else false
        end
      rescue ArgumentError
        false
      end

      def ed25519?(key, signature, content)
        key.verify(nil, signature, content)
      rescue OpenSSL::PKey::PKeyError
        false
      end

      def hmac?(secret, signature, content)
        OpenSSL.secure_compare(OpenSSL::HMAC.digest("SHA256", secret, content), signature)
      end
    end
  end
end
