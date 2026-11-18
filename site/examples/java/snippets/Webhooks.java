package snippets;

import app.suiss.relay.VerifiedWebhook;
import app.suiss.relay.WebhookVerificationException;
import app.suiss.relay.WebhookVerifier;
import com.sun.net.httpserver.HttpExchange;
import java.io.IOException;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

public final class Webhooks {
  private static final Set<String> PROCESSED = ConcurrentHashMap.newKeySet();

  private Webhooks() {}

  // #region verify
  static final WebhookVerifier VERIFIER =
      WebhookVerifier.builder().key(System.getenv("RELAY_WEBHOOK_PUBLIC_KEY")).build();

  static void handle(HttpExchange exchange) throws IOException {
    byte[] rawBody = exchange.getRequestBody().readAllBytes();
    int status;
    try {
      VerifiedWebhook webhook = VERIFIER.verify(exchange.getRequestHeaders(), rawBody);
      if (PROCESSED.add(webhook.id())) {
        System.out.println("received " + webhook.id());
      }
      status = 204;
    } catch (WebhookVerificationException e) {
      status = 400;
    }
    exchange.sendResponseHeaders(status, -1);
    exchange.close();
  }
  // #endregion verify
}
