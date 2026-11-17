package app.suiss.relay;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

class WebhookVerifierTest {
  private static final JsonNode VECTORS = load();

  private static JsonNode load() {
    try {
      Path path =
          Path.of(System.getProperty("relay.conformance"), "webhooks/vectors/1/signature.json");
      return Json.mapper().readTree(Files.readAllBytes(path));
    } catch (IOException e) {
      throw new IllegalStateException(e);
    }
  }

  private static WebhookVerifier verifier(long now, String... keys) {
    WebhookVerifier.Builder builder =
        WebhookVerifier.builder()
            .clock(Clock.fixed(Instant.ofEpochSecond(now), ZoneOffset.UTC))
            .tolerance(java.time.Duration.ofSeconds(VECTORS.path("tolerance_s").asLong()));
    for (String key : keys) {
      builder.key(key);
    }
    return builder.build();
  }

  private static String ed25519() {
    return VECTORS.path("keys").path("ed25519_public_key").asText();
  }

  private static String hmac() {
    return VECTORS.path("keys").path("hmac_secret").asText();
  }

  private static byte[] hex(String text) {
    return HexFormat.of().parseHex(text);
  }

  private static Map<String, List<String>> headers(String id, long timestamp, String signature) {
    Map<String, List<String>> headers = new LinkedHashMap<>();
    headers.put("Webhook-Id", List.of(id));
    headers.put("webhook-timestamp", List.of(Long.toString(timestamp)));
    headers.put("WEBHOOK-SIGNATURE", List.of(signature));
    return headers;
  }

  private static JsonNode vector(String name) {
    for (JsonNode c : VECTORS.path("cases")) {
      if (c.path("name").asText().equals(name)) {
        return c;
      }
    }
    throw new IllegalArgumentException(name);
  }

  @Test
  @DisplayName("WH-4: every shared vector has the published signed content")
  void signedContent() {
    for (JsonNode c : VECTORS.path("cases")) {
      assertArrayEquals(
          hex(c.path("signed_content_hex").asText()),
          WebhookVerifier.signedContent(
              c.path("webhook_id").asText(),
              c.path("webhook_timestamp").asLong(),
              hex(c.path("body_hex").asText())));
    }
  }

  @Test
  @DisplayName(
      "API-65 WH-4: every shared vector verifies with the key of its scheme, alone or together")
  void vectorsVerify() {
    assertTrue(VECTORS.path("cases").size() >= 3);
    for (JsonNode c : VECTORS.path("cases")) {
      String id = c.path("webhook_id").asText();
      long timestamp = c.path("webhook_timestamp").asLong();
      byte[] body = hex(c.path("body_hex").asText());
      String v1a = c.path("v1a").asText();
      String v1 = c.path("v1").asText();

      assertEquals(
          new VerifiedWebhook(id, timestamp, "v1a"),
          verifier(timestamp, ed25519()).verify(headers(id, timestamp, v1a), body));
      assertEquals(
          new VerifiedWebhook(id, timestamp, "v1"),
          verifier(timestamp, hmac()).verify(headers(id, timestamp, v1), body));
      for (String[] keys : new String[][] {{ed25519()}, {hmac()}, {hmac(), ed25519()}}) {
        verifier(timestamp, keys).verify(headers(id, timestamp, v1 + " " + v1a), body);
      }
      verifier(timestamp, ed25519()).verify(id, Long.toString(timestamp), v1a, body);
    }
  }

  @Test
  @DisplayName("WH-7: the shared rejections are refused with either key")
  void rejections() {
    assertTrue(VECTORS.path("rejections").size() >= 4);
    for (JsonNode r : VECTORS.path("rejections")) {
      JsonNode base = vector(r.path("case").asText());
      String id = r.path("webhook_id").asText(base.path("webhook_id").asText());
      long timestamp = base.path("webhook_timestamp").asLong();
      long now = r.path("now").asLong(timestamp);
      byte[] body = hex(r.path("body_hex").asText(base.path("body_hex").asText()));
      String signature;
      if (r.path("swap_versions").asBoolean(false)) {
        String ed = base.path("v1a").asText().substring(4);
        String mac = base.path("v1").asText().substring(3);
        signature = "v1," + ed + " v1a," + mac;
      } else {
        signature = base.path("v1a").asText() + " " + base.path("v1").asText();
      }
      for (String key : new String[] {ed25519(), hmac()}) {
        WebhookVerifier verifier = verifier(now, key);
        Map<String, List<String>> headers = headers(id, timestamp, signature);
        assertThrows(
            WebhookVerificationException.class,
            () -> verifier.verify(headers, body),
            r.path("name").asText());
      }
    }
  }

  @Test
  @DisplayName("WH-7: the tolerance applies in both directions and names the reason")
  void reasons() {
    JsonNode c = vector("standard-webhooks-reference-body");
    String id = c.path("webhook_id").asText();
    long timestamp = c.path("webhook_timestamp").asLong();
    byte[] body = hex(c.path("body_hex").asText());
    String v1 = c.path("v1").asText();

    assertEquals(
        WebhookVerificationException.Reason.TIMESTAMP_OUT_OF_TOLERANCE,
        reason(verifier(timestamp - 301, hmac()), headers(id, timestamp, v1), body));
    verifier(timestamp + 300, hmac()).verify(headers(id, timestamp, v1), body);
    assertEquals(
        WebhookVerificationException.Reason.MISSING_HEADER,
        reason(verifier(timestamp, hmac()), Map.of(), body));
    Map<String, List<String>> duplicate = headers(id, timestamp, v1);
    duplicate.put("webhook-id", List.of(id));
    assertEquals(
        WebhookVerificationException.Reason.DUPLICATE_HEADER,
        reason(verifier(timestamp, hmac()), duplicate, body));
    assertEquals(
        WebhookVerificationException.Reason.MALFORMED_HEADER,
        reason(verifier(timestamp, hmac()), headers(id, timestamp, "v1,short"), body));
    assertEquals(
        WebhookVerificationException.Reason.NO_MATCHING_SIGNATURE,
        reason(
            verifier(timestamp, hmac()),
            headers(id, timestamp, "v2,abcd " + c.path("v1a").asText()),
            body));
  }

  private static WebhookVerificationException.Reason reason(
      WebhookVerifier verifier, Map<String, List<String>> headers, byte[] body) {
    return assertThrows(WebhookVerificationException.class, () -> verifier.verify(headers, body))
        .reason();
  }
}
