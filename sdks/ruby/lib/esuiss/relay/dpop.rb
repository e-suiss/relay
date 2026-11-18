# frozen_string_literal: true

require "json"
require "openssl"
require "securerandom"

module Esuiss
  module Relay
    # API-41
    # An Ed25519 key that signs RFC 9449 DPoP proofs, one fresh proof per request.
    class DPoPKey
      SPKI_PREFIX = ["302a300506032b6570032100"].pack("H*").freeze

      attr_reader :key

      def initialize(key = OpenSSL::PKey.generate_key("ED25519"))
        @key = key
      end

      def self.public_key(raw)
        OpenSSL::PKey.read(SPKI_PREFIX + raw)
      end

      def public_bytes
        @key.public_to_der[-32..]
      end

      def jwk
        { "kty" => "OKP", "crv" => "Ed25519", "x" => Codec.b64url(public_bytes) }
      end

      def proof(method:, url:, token: nil, nonce: nil, now: Time.now, jti: SecureRandom.random_bytes(16))
        header = { "typ" => "dpop+jwt", "alg" => "Ed25519", "jwk" => jwk }
        claims = {
          "htm" => method.to_s.upcase,
          "htu" => url.split(/[?#]/, 2).first,
          "iat" => now.to_i,
          "jti" => Codec.b64url(jti)
        }
        claims["ath"] = Codec.b64url(OpenSSL::Digest.digest("SHA256", token)) if token
        claims["nonce"] = nonce if nonce
        input = "#{Codec.b64url(JSON.generate(header))}.#{Codec.b64url(JSON.generate(claims))}"
        "#{input}.#{Codec.b64url(@key.sign(nil, input))}"
      end
    end
  end
end
