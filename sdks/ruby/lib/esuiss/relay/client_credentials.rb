# frozen_string_literal: true

require "json"
require "uri"

module Esuiss
  module Relay
    # API-41
    # Access client credentials bound to a DPoP key: discovers Relay's Access client_id and the
    # Access token endpoint, obtains a DPoP-bound token and signs a fresh proof for every request.
    class ClientCredentials
      EARLY_RENEWAL = 30
      DEFAULT_LIFETIME = 60

      attr_reader :dpop_key

      def initialize(issuer:, client_id:, client_secret:, scope: nil, resource: nil,
                     transport: NetHTTPTransport.new, dpop_key: DPoPKey.new, timeout: 30,
                     clock: -> { Time.now })
        @issuer = issuer.chomp("/")
        @client_id = client_id
        @client_secret = client_secret
        @scope = scope
        @resource = resource
        @transport = transport
        @dpop_key = dpop_key
        @timeout = timeout
        @clock = clock
        @lock = Mutex.new
        @token = nil
        @expires_at = nil
      end

      def authorize(method, url)
        token = current_token(url)
        { "Authorization" => "DPoP #{token}",
          "DPoP" => @dpop_key.proof(method: method, url: url, token: token, now: @clock.call) }
      end

      def invalidate
        @lock.synchronize { @token = nil }
      end

      def inspect
        "#<#{self.class.name} issuer=#{@issuer.inspect} client_id=#{@client_id.inspect}>"
      end

      private

      def current_token(url)
        @lock.synchronize do
          @token = nil if @token && @clock.call.to_f >= @expires_at
          @token ||= obtain(url)
        end
      end

      def obtain(url)
        resource = @resource ||= discover_resource(url)
        endpoint, methods = discover_endpoint
        body = request_token(endpoint, methods, resource, nil)
        lifetime = body["expires_in"].is_a?(Integer) ? body["expires_in"] : DEFAULT_LIFETIME
        @expires_at = @clock.call.to_f + [lifetime - EARLY_RENEWAL, 1].max
        body.fetch("access_token")
      end

      def discover_resource(url)
        uri = URI(url)
        origin = "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}"
        document = get_json("#{origin}/.well-known/relay-configuration")
        resource = document["access_client_id"]
        return resource if resource.is_a?(String) && !resource.empty?

        raise TokenError, "the Relay discovery document names no access_client_id"
      end

      def discover_endpoint
        document = get_json("#{@issuer}/.well-known/openid-configuration")
        unless document["issuer"].to_s.chomp("/") == @issuer
          raise TokenError, "the Access discovery document names another issuer"
        end

        endpoint = document["token_endpoint"].to_s
        raise TokenError, "the token endpoint is not an https URL" unless endpoint.start_with?("https://")

        [endpoint, document["token_endpoint_auth_methods_supported"]]
      end

      def request_token(endpoint, methods, resource, nonce)
        response = @transport.call(token_request(endpoint, methods, resource, nonce))
        body = parse(response.body)
        return issued(body) if response.status == 200

        if response.status == 400 && body["error"] == "use_dpop_nonce" && nonce.nil?
          given = response.header("dpop-nonce")
          raise TokenError, "Access asked for a DPoP nonce without naming one" if given.to_s.empty?

          return request_token(endpoint, methods, resource, given)
        end
        raise TokenError, "Access refused the client credentials: #{body['error'] || response.status}"
      end

      def token_request(endpoint, methods, resource, nonce)
        form = { "grant_type" => "client_credentials", "resource" => resource }
        form["scope"] = @scope if @scope
        headers = {
          "Accept" => "application/json",
          "Content-Type" => "application/x-www-form-urlencoded",
          "DPoP" => @dpop_key.proof(method: "POST", url: endpoint, nonce: nonce, now: @clock.call)
        }
        if post_only?(methods)
          form["client_id"] = @client_id
          form["client_secret"] = @client_secret
        else
          headers["Authorization"] = "Basic #{basic}"
        end
        Request.new(method: "POST", url: endpoint, headers: headers, body: URI.encode_www_form(form),
                    timeout: @timeout)
      end

      def basic
        pair = "#{URI.encode_www_form_component(@client_id)}:#{URI.encode_www_form_component(@client_secret)}"
        Codec.b64(pair)
      end

      def post_only?(methods)
        methods.is_a?(Array) && methods.include?("client_secret_post") &&
          !methods.include?("client_secret_basic")
      end

      def issued(body)
        token = body["access_token"]
        raise TokenError, "Access answered without an access token" unless token.is_a?(String) && !token.empty?
        raise TokenError, "Access issued a token that is not a DPoP token" unless body["token_type"].to_s.casecmp?("dpop")

        body
      end

      def get_json(url)
        request = Request.new(method: "GET", url: url, headers: { "Accept" => "application/json" }, body: nil,
                              timeout: @timeout)
        response = @transport.call(request)
        raise TokenError, "discovery at #{url} answered HTTP #{response.status}" unless response.status == 200

        parse(response.body)
      end

      def parse(body)
        parsed = JSON.parse(body.to_s)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end
    end
  end
end
