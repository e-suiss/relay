# frozen_string_literal: true

require "test_helper"

class ClientCredentialsTest < Minitest::Test
  include TestSupport

  ISSUER = "https://access.test/r/main"
  ENDPOINT = "https://access.test/oauth2/token"
  NOW = Time.at(1_800_000_000)

  def decode(part)
    JSON.parse(Esuiss::Relay::Codec.decode_b64url(part))
  end

  def discovery_responses(methods = nil)
    openid = { "issuer" => ISSUER, "token_endpoint" => ENDPOINT }
    openid["token_endpoint_auth_methods_supported"] = methods if methods
    [TestSupport.json(200, { "access_client_id" => "relay-client" }), TestSupport.json(200, openid)]
  end

  def credentials(transport, **options)
    Esuiss::Relay::ClientCredentials.new(issuer: ISSUER, client_id: "cli_1", client_secret: "s3cr3t",
                                         transport: transport, clock: -> { NOW }, **options)
  end

  def test_api41_dpop_proof_is_signed_by_the_jwk_and_binds_the_token
    key = Esuiss::Relay::DPoPKey.new
    proof = key.proof(method: "post", url: "https://relay.test/v1/events?x=1#f", token: "tok", now: NOW)
    header_part, claims_part, signature = proof.split(".")
    header = decode(header_part)
    claims = decode(claims_part)

    assert_equal({ "typ" => "dpop+jwt", "alg" => "Ed25519" }, header.slice("typ", "alg"))
    assert_equal %w[OKP Ed25519], header.fetch("jwk").values_at("kty", "crv")
    assert_equal "POST", claims.fetch("htm")
    assert_equal "https://relay.test/v1/events", claims.fetch("htu")
    assert_equal NOW.to_i, claims.fetch("iat")
    assert_equal Esuiss::Relay::Codec.b64url(OpenSSL::Digest::SHA256.digest("tok")), claims.fetch("ath")
    assert_equal 22, claims.fetch("jti").length
    public_key = Esuiss::Relay::DPoPKey.public_key(Esuiss::Relay::Codec.decode_b64url(header.dig("jwk", "x")))

    assert public_key.verify(nil, Esuiss::Relay::Codec.decode_b64url(signature), "#{header_part}.#{claims_part}")
    refute_equal proof, key.proof(method: "post", url: "https://relay.test/v1/events", token: "tok", now: NOW)
  end

  def test_api41_client_credentials_flow_with_basic_auth_and_cached_token
    transport = StubTransport.new(*discovery_responses,
                                  TestSupport.json(200, { "access_token" => "tok-1", "token_type" => "DPoP",
                                                          "expires_in" => 300 }))
    auth = credentials(transport, scope: "publish")
    first = auth.authorize("POST", "https://relay.test/v1/events")
    second = auth.authorize("GET", "https://relay.test/v1/notifications")

    assert_equal "DPoP tok-1", first.fetch("Authorization")
    assert_equal "DPoP tok-1", second.fetch("Authorization")
    refute_equal first.fetch("DPoP"), second.fetch("DPoP")
    assert_equal 3, transport.requests.size
    discovery, openid, token = transport.requests

    assert_equal "https://relay.test/.well-known/relay-configuration", discovery.url
    assert_equal "#{ISSUER}/.well-known/openid-configuration", openid.url
    assert_equal ENDPOINT, token.url
    assert_equal "Basic #{Esuiss::Relay::Codec.b64('cli_1:s3cr3t')}", token.headers["Authorization"]
    form = URI.decode_www_form(token.body).to_h

    assert_equal({ "grant_type" => "client_credentials", "resource" => "relay-client", "scope" => "publish" }, form)
    refute decode(token.headers["DPoP"].split(".")[1]).key?("ath")
  end

  def test_api41_use_dpop_nonce_is_answered_once_and_post_only_issuers_get_form_credentials
    nonce = Esuiss::Relay::Response.new(status: 400, headers: { "DPoP-Nonce" => "n-1" },
                                        body: JSON.generate({ "error" => "use_dpop_nonce" }))
    transport = StubTransport.new(*discovery_responses(["client_secret_post"]), nonce,
                                  TestSupport.json(200, { "access_token" => "tok-2", "token_type" => "dpop" }))
    auth = credentials(transport)

    assert_equal "DPoP tok-2", auth.authorize("GET", "https://relay.test/v1/notifications").fetch("Authorization")
    retried = transport.requests.last

    assert_equal "n-1", decode(retried.headers["DPoP"].split(".")[1]).fetch("nonce")
    assert_nil retried.headers["Authorization"]
    assert_equal "s3cr3t", URI.decode_www_form(retried.body).to_h.fetch("client_secret")
  end

  def test_api41_invalidate_fetches_a_new_token
    transport = StubTransport.new(*discovery_responses,
                                  TestSupport.json(200, { "access_token" => "tok-1", "token_type" => "DPoP" }),
                                  TestSupport.json(200, { "issuer" => ISSUER, "token_endpoint" => ENDPOINT }),
                                  TestSupport.json(200, { "access_token" => "tok-2", "token_type" => "DPoP" }))
    auth = credentials(transport)
    auth.authorize("GET", "https://relay.test/v1/notifications")
    auth.invalidate

    assert_equal "DPoP tok-2", auth.authorize("GET", "https://relay.test/v1/notifications").fetch("Authorization")
  end

  def test_api41_refusals_raise_token_errors
    bearer = TestSupport.json(200, { "access_token" => "tok", "token_type" => "Bearer" })

    assert_raises(Esuiss::Relay::TokenError) do
      credentials(StubTransport.new(*discovery_responses, bearer)).authorize("GET", "https://relay.test/v1/x")
    end
    other = [TestSupport.json(200, { "access_client_id" => "relay-client" }),
             TestSupport.json(200, { "issuer" => "https://evil.test", "token_endpoint" => ENDPOINT })]

    assert_raises(Esuiss::Relay::TokenError) do
      credentials(StubTransport.new(*other)).authorize("GET", "https://relay.test/v1/x")
    end
  end
end
