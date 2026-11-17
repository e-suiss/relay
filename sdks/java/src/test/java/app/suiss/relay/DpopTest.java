package app.suiss.relay;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.Signature;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Base64;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

class DpopTest {
  private static final Base64.Decoder B64URL = Base64.getUrlDecoder();

  private static JsonNode part(String jws, int index) throws Exception {
    return Json.mapper().readTree(B64URL.decode(jws.split("\\.")[index]));
  }

  private static boolean signed(DpopKey key, String jws) throws Exception {
    String[] parts = jws.split("\\.");
    Signature verifier = Signature.getInstance("Ed25519");
    verifier.initVerify(WebhookVerifier.ed25519(key.publicKey()));
    verifier.update((parts[0] + "." + parts[1]).getBytes(StandardCharsets.US_ASCII));
    return verifier.verify(B64URL.decode(parts[2]));
  }

  @Test
  @DisplayName("X-29: a request proof binds the method, the URL without query and the token")
  void proof() throws Exception {
    DpopKey key = DpopKey.generate();
    byte[] jti = new byte[16];
    String jws =
        key.proof(
            "GET",
            URI.create("https://relay.example.com/v1/waitpoints?state=open#x"),
            "token-1",
            null,
            Instant.ofEpochSecond(1_793_784_600L),
            jti);

    JsonNode header = part(jws, 0);
    JsonNode claims = part(jws, 1);
    assertEquals("dpop+jwt", header.path("typ").asText());
    assertEquals("Ed25519", header.path("alg").asText());
    assertEquals("OKP", header.path("jwk").path("kty").asText());
    assertEquals(
        Base64.getUrlEncoder().withoutPadding().encodeToString(key.publicKey()),
        header.path("jwk").path("x").asText());
    assertEquals("GET", claims.path("htm").asText());
    assertEquals("https://relay.example.com/v1/waitpoints", claims.path("htu").asText());
    assertEquals(1_793_784_600L, claims.path("iat").asLong());
    assertEquals("AAAAAAAAAAAAAAAAAAAAAA", claims.path("jti").asText());
    String ath =
        Base64.getUrlEncoder()
            .withoutPadding()
            .encodeToString(
                MessageDigest.getInstance("SHA-256")
                    .digest("token-1".getBytes(StandardCharsets.US_ASCII)));
    assertEquals(ath, claims.path("ath").asText());
    assertFalse(claims.has("nonce"));
    assertTrue(signed(key, jws));
  }

  @Test
  @DisplayName("X-29: client credentials retry once with the DPoP nonce and cache the token")
  void clientCredentials() throws Exception {
    DpopKey key = DpopKey.generate();
    Stub stub =
        new Stub()
            .reply(400, "{\"error\":\"use_dpop_nonce\"}", "DPoP-Nonce", "n-1")
            .reply(200, "{\"access_token\":\"at-1\",\"token_type\":\"DPoP\",\"expires_in\":600}");
    AccessTokenSource tokens =
        AccessTokenSource.builder()
            .tokenEndpoint(URI.create("https://access.example.com/oauth2/token"))
            .clientId("cli 1")
            .clientSecret("s3cret")
            .resource("relay-client")
            .scope("publish read")
            .key(key)
            .transport(stub)
            .clock(Clock.fixed(Stub.NOW, ZoneOffset.UTC))
            .build();

    assertEquals("at-1", tokens.accessToken());
    assertEquals("at-1", tokens.accessToken());
    assertEquals(2, stub.requests.size());
    Transport.Request first = stub.requests.get(0);
    Transport.Request second = stub.requests.get(1);
    assertEquals(
        "grant_type=client_credentials&resource=relay-client&scope=publish+read",
        new String(first.body(), StandardCharsets.UTF_8));
    assertEquals(
        "Basic " + Base64.getEncoder().encodeToString("cli+1:s3cret".getBytes(StandardCharsets.UTF_8)),
        first.header("Authorization"));
    assertNull(part(first.header("DPoP"), 1).get("nonce"));
    assertFalse(part(first.header("DPoP"), 1).has("ath"));
    assertEquals("n-1", part(second.header("DPoP"), 1).path("nonce").asText());
    assertTrue(signed(key, second.header("DPoP")));
  }

  @Test
  @DisplayName("X-29: a bearer token is refused")
  void bearerRefused() {
    Stub stub = new Stub().reply(200, "{\"access_token\":\"at-1\",\"token_type\":\"Bearer\"}");
    AccessTokenSource tokens =
        AccessTokenSource.builder()
            .tokenEndpoint(URI.create("https://access.example.com/oauth2/token"))
            .clientId("cli")
            .clientSecret("secret")
            .resource("relay-client")
            .key(DpopKey.generate())
            .transport(stub)
            .build();

    assertThrows(AuthenticationException.class, tokens::accessToken);
  }
}
