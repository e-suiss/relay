# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module Esuiss
  module Relay
    # One HTTP request handed to a transport.
    Request = Struct.new(:method, :url, :headers, :body, :timeout, keyword_init: true)

    # One HTTP answer: status, headers with lowercase names, and the raw body.
    class Response
      attr_reader :status, :headers, :body

      def initialize(status:, headers: {}, body: "")
        @status = status
        @headers = headers.to_h { |name, value| [name.to_s.downcase, value] }
        @body = body || ""
      end

      def header(name)
        @headers[name.to_s.downcase]
      end
    end

    # The default transport over Net::HTTP. Any object answering `call(request)` with a Response
    # can replace it.
    class NetHTTPTransport
      FAILURES = [Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError].freeze

      def call(request)
        uri = URI(request.url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = request.timeout
        http.read_timeout = request.timeout
        http.write_timeout = request.timeout
        answer = http.start { |connection| connection.request(build(uri, request)) }
        headers = {}
        answer.each_header { |name, value| headers[name] = value }
        Response.new(status: answer.code.to_i, headers: headers, body: answer.body)
      rescue *FAILURES => e
        raise ConnectionError, "Relay is unreachable: #{e.class}: #{e.message}"
      end

      private

      def build(uri, request)
        net = Net::HTTPGenericRequest.new(request.method, !request.body.nil?, true, uri.request_uri,
                                          request.headers)
        net.body = request.body unless request.body.nil?
        net
      end
    end
  end
end
