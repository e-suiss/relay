defmodule Relay.Access.DpopTest do
  use ExUnit.Case, async: true

  alias Relay.Access.Dpop
  alias RelayTest.Dpop, as: Proof

  @url "https://relay.test/v1/events"
  @token "header.claims.signature"

  defp request(method \\ "POST"),
    do: %{method: method, url: @url, now: System.system_time(:second)}

  defp verify(proof, request \\ request()), do: Dpop.verify(proof, @token, Proof.jkt(), request)

  defp refused?({:error, %Relay.Error{code: :auth_invalid_token, details: details}}),
    do: details[:challenge] == "invalid_dpop_proof"

  defp refused?(_result), do: false

  describe "E-93 DPoP proofs" do
    test "E-93: a proof of the token's key for the request verifies" do
      assert {:ok, %{jti: jti, jkt: jkt, iat: iat}} = verify(Proof.proof(:post, @url, @token))
      assert is_binary(jti) and is_integer(iat)
      assert jkt == Proof.jkt()
    end

    test "E-93: htu is compared without query, fragment, case of scheme and host, or default port" do
      for htu <- ["https://RELAY.test:443/v1/events?x=1", "HTTPS://relay.test/v1/events#f"] do
        assert {:ok, _} = verify(Proof.proof(:post, @url, @token, claims: %{"htu" => htu}))
      end

      refute Dpop.same_url?("https://relay.test:8443/v1/events", @url)
      refute Dpop.same_url?("http://relay.test/v1/events", @url)
      refute Dpop.same_url?("/v1/events", @url)
      refute Dpop.same_url?(nil, @url)
    end

    test "E-93: a proof that does not fit the request, the token, the key or the clock is refused" do
      now = System.system_time(:second)
      private_jwk = Map.put(Proof.jwk(), "d", "c2VjcmV0")

      proofs = [
        Proof.proof(:get, @url, @token),
        Proof.proof(:post, "https://relay.test/v1/other", @token),
        Proof.proof(:post, @url, "another.token.value"),
        Proof.proof(:post, @url, nil),
        Proof.proof(:post, @url, @token, key: Proof.key()),
        Proof.proof(:post, @url, @token, claims: %{"iat" => now - 120}),
        Proof.proof(:post, @url, @token, claims: %{"iat" => now + 120}),
        Proof.proof(:post, @url, @token, claims: %{"iat" => nil}),
        Proof.proof(:post, @url, @token, claims: %{"jti" => nil}),
        Proof.proof(:post, @url, @token, header: %{"typ" => "JWT"}),
        Proof.proof(:post, @url, @token, header: %{"alg" => "PS256"}),
        Proof.proof(:post, @url, @token, header: %{"alg" => "none"}),
        Proof.proof(:post, @url, @token, header: %{"jwk" => private_jwk}),
        Proof.proof(:post, @url, @token, header: %{"jwk" => nil}),
        Proof.proof(:post, @url, @token) <> "x",
        "not-a-proof",
        nil
      ]

      for proof <- proofs do
        assert refused?(verify(proof)), inspect(proof)
      end
    end

    test "E-93: a token without cnf.jkt is not DPoP-bound" do
      proof = Proof.proof(:post, @url, @token)

      for claims <- [%{}, %{"cnf" => %{"x5t#S256" => "abc"}}, %{"cnf" => %{"jkt" => 7}}] do
        assert {:error, %Relay.Error{code: :auth_invalid_token}} =
                 Dpop.check(proof, @token, claims, request())
      end
    end

    test "E-93: the RFC 7638 thumbprint of a JWK" do
      rsa = %{
        "kty" => "RSA",
        "n" =>
          "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw",
        "e" => "AQAB",
        "alg" => "RS256",
        "kid" => "2011-04-29"
      }

      assert Dpop.thumbprint(rsa) == {:ok, "NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs"}
      assert Dpop.thumbprint(Map.put(Proof.jwk(), "kid", "ignored")) == {:ok, Proof.jkt()}
      assert Dpop.thumbprint(%{"kty" => "oct", "k" => "c2VjcmV0"}) == :error
    end

    test "E-93: the ath of a token is the unpadded base64url SHA-256 of its bytes" do
      assert Dpop.token_hash(@token) == Proof.ath(@token)
      refute String.contains?(Dpop.token_hash(@token), "=")
    end
  end
end
