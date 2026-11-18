package app.suiss.relay;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import app.suiss.relay.params.ListNotificationsParams;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.spec.PKCS8EncodedKeySpec;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Base64;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

@EnabledIfEnvironmentVariable(named = "SDK_LIVE_BASE_URL", matches = ".+")
class LiveSmokeTest {
  private static final byte[] PKCS8_PREFIX =
      HexFormat.of().parseHex("302e020100300506032b657004220420");

  private static String env(String name) {
    return System.getenv(name);
  }

  private static DpopKey key() throws Exception {
    byte[] seed = Base64.getDecoder().decode(env("SDK_LIVE_DPOP_SEED"));
    byte[] x = Base64.getUrlDecoder().decode(env("SDK_LIVE_DPOP_X"));
    byte[] pkcs8 = new byte[PKCS8_PREFIX.length + seed.length];
    System.arraycopy(PKCS8_PREFIX, 0, pkcs8, 0, PKCS8_PREFIX.length);
    System.arraycopy(seed, 0, pkcs8, PKCS8_PREFIX.length, seed.length);
    KeyFactory factory = KeyFactory.getInstance("Ed25519");
    return DpopKey.of(
        new KeyPair(
            WebhookVerifier.ed25519(x), factory.generatePrivate(new PKCS8EncodedKeySpec(pkcs8))));
  }

  @Test
  @DisplayName(
      "X-48: the SDK sends an event, pages notifications and verifies a webhook on a live test plane")
  void smoke() throws Exception {
    RelayClient relay =
        RelayClient.builder()
            .baseUrl(env("SDK_LIVE_BASE_URL"))
            .credentials(DpopCredentials.of(key(), env("SDK_LIVE_TOKEN")))
            .build();

    ObjectNode event = Json.object().put("workflow", env("SDK_LIVE_WORKFLOW"));
    event.putArray("to").add(env("SDK_LIVE_RECIPIENT"));
    JsonNode accepted = relay.api().createEvent(event);
    assertTrue(accepted.hasNonNull("id"), accepted.toString());

    int seen = 0;
    for (JsonNode ignored :
        relay
            .api()
            .listNotifications(new ListNotificationsParams().limit(2), RequestOptions.none())
            .autoPaging()) {
      if (++seen >= 6) {
        break;
      }
    }

    JsonNode vectors =
        Json.mapper().readTree(Files.readAllBytes(Path.of(env("SDK_LIVE_WEBHOOK_VECTORS"))));
    JsonNode vector = vectors.path("cases").get(0);
    long timestamp = vector.path("webhook_timestamp").asLong();
    WebhookVerifier verifier =
        WebhookVerifier.builder()
            .key(vectors.path("keys").path("ed25519_public_key").asText())
            .clock(Clock.fixed(Instant.ofEpochSecond(timestamp), ZoneOffset.UTC))
            .build();
    VerifiedWebhook verified =
        verifier.verify(
            Map.of(
                "webhook-id", List.of(vector.path("webhook_id").asText()),
                "webhook-timestamp", List.of(Long.toString(timestamp)),
                "webhook-signature", List.of(vector.path("v1a").asText())),
            HexFormat.of().parseHex(vector.path("body_hex").asText()));
    assertEquals("v1a", verified.scheme());
  }
}
