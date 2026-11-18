package snippets;

import app.suiss.relay.AccessTokenSource;
import app.suiss.relay.DpopCredentials;
import app.suiss.relay.DpopKey;
import app.suiss.relay.Json;
import app.suiss.relay.RelayClient;
import app.suiss.relay.ValidationException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.net.URI;

public final class Quickstart {
  private Quickstart() {}

  static void run() {
    // #region quickstart
    DpopKey key = DpopKey.generate();

    RelayClient relay =
        RelayClient.builder()
            .baseUrl("https://relay.example.com")
            .credentials(
                DpopCredentials.of(
                    key,
                    AccessTokenSource.builder()
                        .tokenEndpoint(URI.create("https://access.example.com/oauth2/token"))
                        .clientId(System.getenv("ACCESS_CLIENT_ID"))
                        .clientSecret(System.getenv("ACCESS_CLIENT_SECRET"))
                        .resource(System.getenv("RELAY_ACCESS_CLIENT_ID"))
                        .key(key)
                        .build()))
            .build();

    ObjectNode event = Json.object().put("workflow", "welcome");
    event.putArray("to").addObject().put("id", "user-4821").put("email", "ayse@example.com");
    event.putObject("data").put("first_name", "Ayşe");
    JsonNode accepted = relay.api().createEvent(event);
    System.out.println(accepted.path("id").asText());
    // #endregion quickstart

    // #region decisions
    for (JsonNode decision : relay.api().listSubscriberDecisions("user-4821").autoPaging()) {
      System.out.println(decision.path("notification_id").asText());
    }
    // #endregion decisions

    // #region errors
    try {
      relay.api().createEvent(Json.object().put("workflow", "welcome"));
    } catch (ValidationException e) {
      System.out.println(e.code() + " " + e.detail() + " request " + e.requestId());
    }
    // #endregion errors
  }
}
