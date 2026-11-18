package app.suiss.relay;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import app.suiss.relay.params.QueryParams;
import com.fasterxml.jackson.databind.JsonNode;
import java.io.IOException;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

class ConformanceTest {
  private static final Path ROOT = Path.of(System.getProperty("relay.conformance"));

  private static JsonNode vectors(String name) {
    try {
      return Json.mapper().readTree(Files.readAllBytes(ROOT.resolve("sdk/vectors/1/" + name)));
    } catch (IOException e) {
      throw new IllegalStateException(e);
    }
  }

  private static final class Raw extends QueryParams<Raw> {
    Raw put(String name, String value) {
      return set(name, value);
    }

    @Override
    protected Raw self() {
      return this;
    }
  }

  private static Transport.Response response(JsonNode r) {
    Map<String, List<String>> headers = new LinkedHashMap<>();
    r.path("headers")
        .properties()
        .forEach(h -> headers.put(h.getKey(), List.of(h.getValue().asText())));
    JsonNode body = r.path("body");
    byte[] bytes;
    if (body.isMissingNode() || body.isNull()) {
      bytes = new byte[0];
    } else if (body.isTextual()) {
      bytes = body.textValue().getBytes(StandardCharsets.UTF_8);
    } else {
      bytes = Json.write(body);
    }
    return new Transport.Response(r.path("status").asInt(), headers, bytes);
  }

  private static Class<? extends ApiException> javaClass(String name) {
    return switch (name) {
      case "auth" -> AuthenticationException.class;
      case "validation" -> ValidationException.class;
      case "rate_limit" -> RateLimitException.class;
      case "idempotency" -> IdempotencyException.class;
      case "server" -> ServerException.class;
      default -> throw new IllegalArgumentException(name);
    };
  }

  private static RelayClient client(Stub stub, JsonNode policy, double random, Instant now) {
    return RelayClient.builder()
        .baseUrl("https://relay.example.com")
        .credentials(DpopCredentials.of(DpopKey.generate(), "token-1"))
        .transport(stub)
        .maxRetries(policy.path("max_retries").asInt(3))
        .baseDelay(Duration.ofMillis(policy.path("base_ms").asLong(500)))
        .maxDelay(Duration.ofMillis(policy.path("cap_ms").asLong(8000)))
        .maxRetryAfter(Duration.ofSeconds(policy.path("max_retry_after_s").asLong(60)))
        .sleeper(stub.sleeps::add)
        .clock(Clock.fixed(now, ZoneOffset.UTC))
        .random(new Stub.FixedRandom(random))
        .build();
  }

  @Test
  @DisplayName("X-29 API-38: the error vectors give each response its class and retryable flag")
  void errors() {
    JsonNode v = vectors("errors.json");
    Instant now = Instant.parse("2026-11-18T10:00:00Z");
    for (JsonNode c : v.path("cases")) {
      String name = c.path("name").asText();
      JsonNode expect = c.path("expect");
      Problem problem = Problem.of(response(c.path("response")), now);
      assertEquals(expect.path("class").asText(), problem.errorClass(), name);
      assertEquals(expect.path("status").asInt(), problem.status(), name);
      assertEquals(
          expect.path("code").isNull() ? null : expect.path("code").asText(), problem.code(), name);
      assertEquals(expect.path("retryable").asBoolean(), problem.retryable(), name);
      ApiException error = problem.toException();
      assertInstanceOf(javaClass(expect.path("class").asText()), error, name);
      if (expect.has("request_id")) {
        assertEquals(expect.path("request_id").asText(), error.requestId(), name);
      }
      if (expect.has("retry_after_s")) {
        assertEquals(
            Duration.ofSeconds(expect.path("retry_after_s").asLong()), error.retryAfter(), name);
      }
      if (expect.has("field_errors")) {
        assertEquals(expect.path("field_errors").asInt(), error.fieldErrors().size(), name);
      }
    }
  }

  @Test
  @DisplayName("API-38: the error vectors' catalog and status defaults match the generated catalog")
  void catalogCopy() {
    JsonNode v = vectors("errors.json");
    assertEquals(v.path("catalog").size(), ErrorCatalog.CODES.size());
    for (JsonNode entry : v.path("catalog")) {
      ErrorCatalog.Entry generated = ErrorCatalog.CODES.get(entry.path("code").asText());
      assertEquals(
          new ErrorCatalog.Entry(
              entry.path("family").asText(),
              entry.path("status").asInt(),
              entry.path("retryable").asBoolean()),
          generated);
    }
    List<ErrorCatalog.Default> defaults = new ArrayList<>();
    for (JsonNode d : v.path("status_defaults")) {
      defaults.add(
          new ErrorCatalog.Default(
              d.path("status").asInt(),
              d.has("code") ? d.path("code").asText() : null,
              d.path("retryable").asBoolean()));
    }
    assertEquals(defaults, ErrorCatalog.DEFAULTS);
  }

  @Test
  @DisplayName("X-29 API-49: the retry vectors give every decision and wait")
  void retry() {
    JsonNode v = vectors("retry.json");
    JsonNode policy = v.path("policy");
    Requester requester = client(new Stub(), policy, 0.5, Stub.NOW).requester();
    for (JsonNode b : v.path("backoff")) {
      long delay =
          requester.backoff(b.path("retry").asInt(), b.path("random").asDouble()).toMillis();
      assertEquals(b.path("delay_ms").asLong(), delay, b.toString());
      assertTrue(delay >= b.path("min_ms").asLong() && delay <= b.path("max_ms").asLong());
    }
    for (JsonNode c : v.path("decisions")) {
      String name = c.path("name").asText();
      Instant now = Instant.parse(c.path("now").asText());
      Transport.Response response =
          c.path("network_error").asBoolean(false) ? null : response(c.path("response"));
      Requester.Decision decision =
          requester.decide(c.path("retry").asInt(), c.path("random").asDouble(), now, response);
      JsonNode expect = c.path("expect");
      assertEquals(expect.path("retry").asBoolean(), decision.retry(), name);
      if (decision.retry()) {
        assertEquals(expect.path("delay_ms").asLong(), decision.delay().toMillis(), name);
      } else {
        assertEquals(expect.path("reason").asText(), decision.reason(), name);
      }
    }
  }

  @Test
  @DisplayName("X-29 API-10: the idempotency vectors keep one key per call across retries")
  void idempotency() {
    JsonNode v = vectors("idempotency.json");
    for (JsonNode c : v.path("cases")) {
      String name = c.path("name").asText();
      Stub stub = new Stub();
      RelayClient client = client(stub, Json.object(), 0.5, Stub.NOW);
      Set<String> callKeys = new HashSet<>();
      int calls = 0;
      for (JsonNode call : c.path("calls")) {
        calls++;
        int before = stub.requests.size();
        for (JsonNode r : call.path("responses")) {
          if (r.path("network_error").asBoolean(false)) {
            stub.fail("network error");
          } else {
            stub.answer(request -> response(r));
          }
        }
        String method = call.path("method").asText();
        Operation op =
            new Operation(
                name,
                method,
                call.path("path").asText(),
                call.path("takes_idempotency_key").asBoolean()
                    ? Operation.Presence.REQUIRED
                    : Operation.Presence.NONE,
                Operation.Presence.NONE,
                method.equals("GET") ? Operation.Presence.NONE : Operation.Presence.OPTIONAL,
                "application/json",
                Operation.Response.JSON);
        boolean[] replayed = {false};
        RequestOptions.Builder options =
            RequestOptions.builder().onResponse(info -> replayed[0] = info.replayed());
        if (call.has("caller_idempotency")) {
          options.idempotencyKey(call.path("caller_idempotency").asText());
        }
        JsonNode expect = call.path("expect");
        JsonNode body = method.equals("GET") ? null : Json.object();
        if (expect.path("outcome").asText().equals("success")) {
          client.requester().execute(op, List.of(), Map.of(), body, options.build());
          assertEquals(expect.path("replayed").asBoolean(), replayed[0], name);
        } else {
          ApiException error =
              assertThrows(
                  ApiException.class,
                  () -> client.requester().execute(op, List.of(), Map.of(), body, options.build()));
          assertInstanceOf(javaClass(expect.path("error_class").asText()), error, name);
          assertEquals(expect.path("error_code").asText(), error.code(), name);
        }
        List<Transport.Request> sent = stub.requests.subList(before, stub.requests.size());
        assertEquals(expect.path("requests").asInt(), sent.size(), name);
        Set<String> keys = new HashSet<>();
        for (Transport.Request request : sent) {
          String key = request.header("Idempotency-Key");
          assertEquals(expect.path("key_sent").asBoolean(), key != null, name);
          if (key != null) {
            assertTrue(key.length() >= v.path("key_length").path("min").asInt(), name);
            assertTrue(key.length() <= v.path("key_length").path("max").asInt(), name);
            keys.add(key);
          }
        }
        if (expect.path("key_sent").asBoolean()) {
          assertEquals(1, keys.size(), name);
          callKeys.addAll(keys);
        }
        if (expect.has("sent_idempotency")) {
          assertEquals(Set.of(expect.path("sent_idempotency").asText()), keys, name);
        }
      }
      if (calls > 1 && !callKeys.isEmpty() && !c.path("calls").get(0).has("caller_idempotency")) {
        assertEquals(calls, callKeys.size(), name);
      }
    }
  }

  private static Map<String, String> query(URI uri) {
    Map<String, String> out = new LinkedHashMap<>();
    String raw = uri.getRawQuery();
    if (raw == null) {
      return out;
    }
    for (String pair : raw.split("&")) {
      int eq = pair.indexOf('=');
      out.put(
          URLDecoder.decode(pair.substring(0, eq), StandardCharsets.UTF_8),
          URLDecoder.decode(pair.substring(eq + 1), StandardCharsets.UTF_8));
    }
    return out;
  }

  @Test
  @DisplayName("API-56: the pagination vectors fetch pages lazily in both directions")
  void pagination() {
    JsonNode v = vectors("pagination.json");
    Operation op =
        new Operation(
            "listNotifications",
            "GET",
            "/v1/notifications",
            Operation.Presence.NONE,
            Operation.Presence.NONE,
            Operation.Presence.NONE,
            "application/json",
            Operation.Response.JSON);
    for (JsonNode c : v.path("cases")) {
      String name = c.path("name").asText();
      Stub stub = new Stub();
      for (JsonNode exchange : c.path("exchanges")) {
        stub.answer(
            request -> {
              Map<String, String> expected = new LinkedHashMap<>();
              exchange
                  .path("query")
                  .properties()
                  .forEach(q -> expected.put(q.getKey(), q.getValue().asText()));
              assertEquals(expected, query(request.uri()), name);
              return Stub.response(200, Json.writeString(exchange.path("page")));
            });
      }
      Raw params = new Raw();
      c.path("params").properties().forEach(p -> params.put(p.getKey(), p.getValue().asText()));
      Page page =
          client(stub, Json.object(), 0.5, Stub.NOW)
              .requester()
              .page(op, List.of(), params, RequestOptions.none());
      int take = c.path("take").asInt(Integer.MAX_VALUE);
      List<String> items = new ArrayList<>();
      Iterator<JsonNode> walk = page.autoPaging().iterator();
      while (items.size() < take && walk.hasNext()) {
        items.add(walk.next().path("id").asText());
      }
      List<String> expected = new ArrayList<>();
      c.path("expect").path("items").forEach(i -> expected.add(i.asText()));
      assertEquals(expected, items, name);
      assertEquals(c.path("expect").path("requests").asInt(), stub.requests.size(), name);
    }
  }

  @Test
  @DisplayName("API-65 WH-4 WH-7: the webhook vectors verify or refuse with the named reason")
  void webhooks() throws IOException {
    JsonNode v = vectors("webhooks.json");
    JsonNode signatures =
        Json.mapper()
            .readTree(Files.readAllBytes(ROOT.resolve("webhooks/vectors/1/signature.json")));
    Map<String, JsonNode> bases = new LinkedHashMap<>();
    signatures.path("cases").forEach(b -> bases.put(b.path("name").asText(), b));
    for (JsonNode c : v.path("cases")) {
      String name = c.path("name").asText();
      JsonNode base = bases.get(c.path("base").asText());
      long timestamp = base.path("webhook_timestamp").asLong();
      Map<String, List<String>> headers = new LinkedHashMap<>();
      headers.put("webhook-id", List.of(base.path("webhook_id").asText()));
      headers.put("webhook-timestamp", List.of(Long.toString(timestamp)));
      headers.put("webhook-signature", List.of(base.path("v1a").asText()));
      for (Map.Entry<String, JsonNode> h : c.path("headers").properties()) {
        headers.remove(h.getKey());
        if (!h.getValue().isNull()) {
          String value =
              h.getValue()
                  .asText()
                  .replace("{v1a}", base.path("v1a").asText())
                  .replace("{v1}", base.path("v1").asText());
          headers.put(h.getKey(), List.of(value));
        }
      }
      WebhookVerifier.Builder builder =
          WebhookVerifier.builder()
              .tolerance(Duration.ofSeconds(signatures.path("tolerance_s").asLong()))
              .clock(
                  Clock.fixed(
                      Instant.ofEpochSecond(c.path("now").asLong(timestamp)), ZoneOffset.UTC));
      c.path("keys").forEach(k -> builder.key(signatures.path("keys").path(k.asText()).asText()));
      WebhookVerifier verifier = builder.build();
      byte[] body =
          HexFormat.of().parseHex(c.path("body_hex").asText(base.path("body_hex").asText()));
      JsonNode expect = c.path("expect");
      if (expect.path("ok").asBoolean()) {
        assertEquals(expect.path("scheme").asText(), verifier.verify(headers, body).scheme(), name);
      } else {
        WebhookVerificationException error =
            assertThrows(
                WebhookVerificationException.class, () -> verifier.verify(headers, body), name);
        assertEquals(
            expect.path("error").asText().toUpperCase(Locale.ROOT), error.reason().name(), name);
      }
    }
    assertFalse(v.path("cases").isEmpty());
    assertNotEquals(0, signatures.path("rejections").size());
  }
}
