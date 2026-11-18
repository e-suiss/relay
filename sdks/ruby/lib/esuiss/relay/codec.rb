# frozen_string_literal: true

module Esuiss
  module Relay
    # Base64 helpers without the base64 gem.
    module Codec
      module_function

      def b64(bytes)
        [bytes].pack("m0")
      end

      def b64url(bytes)
        b64(bytes).tr("+/", "-_").delete("=")
      end

      def decode_b64(text)
        text.unpack1("m0")
      end

      def decode_b64url(text)
        padded = text.tr("-_", "+/")
        padded += "=" * ((4 - (padded.length % 4)) % 4)
        decode_b64(padded)
      end
    end
  end
end
