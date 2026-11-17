package app.suiss.relay;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import app.suiss.relay.params.ListWaitpointsParams;
import com.fasterxml.jackson.databind.JsonNode;
import java.time.Duration;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

class RequesterTest {
  private static final String WAITPOINT = "{\"object\":\"waitpoint\",\"id\":\"wp_1\"}";

  private static String problem(int status, String code, Boolean retryable) {
    return "{\"type\":\"https://relay.example.com/v1/errors/"
        + code
        + "\",\"title\":\"t\",\"status\":"
        + status
        + ",\"code\":\""
        + code
        + "\""
        + (retryable == null ? "" : ",\"retryable\":" + retryable)
        + ",\"request_id\":\"req_1\"}";
  }

  @Test
  @DisplayName(
      "X-29 API-10: a mutating request carries one generated idempotency key on every retry")
  void idempotencyKeyIsReused() {
    Stub stub =
        new Stub()
            .reply(503, problem(503, "service_unavailable", true), "Retry-After", "5")
            .fail("connection reset")
            .reply(201, WAITPOINT);
    JsonNode created = stub.client().api().createWaitpoint(Json.object().put("kind", "event"));

    assertEquals("wp_1", created.path("id").asText());
    assertEquals(3, stub.requests.size());
    Set<String> keys =
        stub.requests.stream().map(r -> r.header("Idempotency-Key")).collect(Collectors.toSet());
    assertEquals(1, keys.size());
    String key = keys.iterator().next();
    assertNotNull(key);
    assertTrue(key.length() >= 8 && key.length() <= 255);
    Set<String> proofs =
        stub.requests.stream().map(r -> r.header("DPoP")).collect(Collectors.toSet());
    assertEquals(3, proofs.size());
  }

  @Test
  @DisplayName("X-29 API-10: a caller's own idempotency key is sent unchanged")
  void ownIdempotencyKey() {
    Stub stub = new Stub().reply(201, WAITPOINT);
    stub.client()
        .api()
        .createWaitpoint(
            Json.object(), RequestOptions.builder().idempotencyKey("order-4821-shipped").build());

    assertEquals("order-4821-shipped", stub.requests.get(0).header("Idempotency-Key"));
  }

  @Test
  @DisplayName("API-10: a read carries no idempotency key")
  void readsCarryNoKey() {
    Stub stub = new Stub().reply(200, WAITPOINT);
    stub.client().api().getWaitpoint("wp_1");

    assertNull(stub.requests.get(0).header("Idempotency-Key"));
    assertEquals(
        "https://relay.example.com/v1/waitpoints/wp_1", stub.requests.get(0).uri().toString());
  }

  @Test
  @DisplayName("API-55: every request is pinned to the contract's API version")
  void versionIsPinned() {
    Stub stub = new Stub().reply(200, WAITPOINT);
    stub.client().api().getWaitpoint("wp_1");

    Transport.Request request = stub.requests.get(0);
    assertEquals(ApiVersion.VALUE, request.header("Relay-Version"));
    assertEquals("2026-11-01", ApiVersion.VALUE);
    assertTrue(request.header("User-Agent").contains("(api " + ApiVersion.VALUE + ")"));
    assertEquals("DPoP token-1", request.header("Authorization"));
  }

  @Test
  @DisplayName("X-29 API-49: Retry-After is waited before the retry")
  void retryAfterIsHonoured() {
    Stub stub =
        new Stub()
            .reply(429, problem(429, "rate_limited", true), "Retry-After", "7")
            .reply(200, WAITPOINT);
    stub.client().api().getWaitpoint("wp_1");

    assertEquals(List.of(Duration.ofSeconds(7)), stub.sleeps);
  }

  @Test
  @DisplayName("X-29: without Retry-After the wait is full jitter under an exponential ceiling")
  void fullJitter() {
    Stub stub =
        new Stub()
            .reply(500, problem(500, "internal_error", true))
            .reply(500, problem(500, "internal_error", true))
            .reply(500, problem(500, "internal_error", true))
            .reply(200, WAITPOINT);
    stub.client().api().getWaitpoint("wp_1");

    assertEquals(
        List.of(Duration.ofMillis(250), Duration.ofMillis(500), Duration.ofMillis(1000)),
        stub.sleeps);
  }

  @Test
  @DisplayName("X-29 API-38: an error Relay marks not retryable is never retried")
  void notRetryable() {
    Stub stub = new Stub().reply(422, problem(422, "validation_failed", false));
    ValidationException error =
        assertThrows(
            ValidationException.class, () -> stub.client().api().createWaitpoint(Json.object()));

    assertEquals(1, stub.requests.size());
    assertEquals("validation_failed", error.code());
    assertEquals("req_1", error.requestId());
  }

  @Test
  @DisplayName("X-29 API-38: the body's retryable flag wins over the status default")
  void bodyFlagWins() {
    Stub stub = new Stub().reply(503, problem(503, "service_unavailable", false));
    assertThrows(ServerException.class, () -> stub.client().api().getWaitpoint("wp_1"));

    assertEquals(1, stub.requests.size());
  }

  @Test
  @DisplayName("X-29: the quota is not retried and is a rate limit error")
  void quotaIsNotRetried() {
    Stub stub = new Stub().reply(429, problem(429, "quota_exhausted", false));
    QuotaException error =
        assertThrows(QuotaException.class, () -> stub.client().api().createEvent(Json.object()));

    assertInstanceOf(RateLimitException.class, error);
    assertEquals(1, stub.requests.size());
  }

  @Test
  @DisplayName("X-29: retries stop after the configured count with the last error")
  void retriesStop() {
    Stub stub =
        new Stub()
            .reply(503, problem(503, "service_unavailable", true), "Retry-After", "1")
            .reply(503, problem(503, "service_unavailable", true), "Retry-After", "1");
    ServerException error =
        assertThrows(ServerException.class, () -> stub.client(1).api().getWaitpoint("wp_1"));

    assertEquals(2, stub.requests.size());
    assertEquals(Duration.ofSeconds(1), error.retryAfter());
  }

  @Test
  @DisplayName("X-29: a Retry-After beyond the limit ends the call instead of waiting")
  void longRetryAfter() {
    Stub stub =
        new Stub().reply(503, problem(503, "service_unavailable", true), "Retry-After", "3600");
    assertThrows(ServerException.class, () -> stub.client().api().getWaitpoint("wp_1"));

    assertEquals(1, stub.requests.size());
    assertTrue(stub.sleeps.isEmpty());
  }

  @Test
  @DisplayName("X-29: an idempotency key still in progress is retried with the same key")
  void inProgress() {
    Stub stub =
        new Stub()
            .reply(409, problem(409, "idempotency_key_in_progress", true), "Retry-After", "1")
            .reply(201, WAITPOINT);
    stub.client().api().createWaitpoint(Json.object());

    assertEquals(
        stub.requests.get(0).header("Idempotency-Key"),
        stub.requests.get(1).header("Idempotency-Key"));
  }

  @Test
  @DisplayName("X-29: a lost connection ends the call when retries are off")
  void connectionError() {
    Stub stub = new Stub().fail("refused");
    assertThrows(ConnectionException.class, () -> stub.client(0).api().getWaitpoint("wp_1"));
  }

  @Test
  @DisplayName("X-29: every error kind maps to its class")
  void hierarchy() {
    Object[][] cases = {
      {401, "auth_invalid_token", AuthenticationException.class},
      {403, "auth_insufficient_scope", AuthenticationException.class},
      {400, "malformed_request", ValidationException.class},
      {422, "unknown_field", ValidationException.class},
      {413, "payload_too_large", ValidationException.class},
      {429, "rate_limited", RateLimitException.class},
      {429, "quota_exhausted", QuotaException.class},
      {400, "idempotency_key_missing", IdempotencyException.class},
      {422, "idempotency_key_reuse", IdempotencyException.class},
      {404, "waitpoint_not_found", NotFoundException.class},
      {409, "resource_conflict", ConflictException.class},
      {412, "precondition_failed", ConflictException.class},
      {500, "internal_error", ServerException.class},
      {503, "service_unavailable", ServerException.class},
    };
    for (Object[] c : cases) {
      int status = (Integer) c[0];
      Stub stub = new Stub().reply(status, problem(status, (String) c[1], false));
      RelayException error =
          assertThrows(RelayException.class, () -> stub.client().api().getWaitpoint("wp_1"));
      assertEquals(c[2], error.getClass(), (String) c[1]);
    }
  }

  @Test
  @DisplayName("API-38: without a body flag the catalog decides whether an error is retryable")
  void catalogDecides() {
    assertTrue(Problem.catalogRetryable(503, "service_unavailable"));
    assertTrue(Problem.catalogRetryable(409, "idempotency_key_in_progress"));
    assertTrue(Problem.catalogRetryable(429, "rate_limited"));
    assertTrue(!Problem.catalogRetryable(429, "quota_exhausted"));
    assertTrue(!Problem.catalogRetryable(409, "resource_conflict"));
    assertTrue(Problem.catalogRetryable(502, null));
    assertTrue(!Problem.catalogRetryable(404, null));
    assertTrue(ErrorCatalog.CODES.size() > 100);
  }

  @Test
  @DisplayName("API-56: query parameters are sent with their wire names")
  void queryParameters() {
    Stub stub =
        new Stub()
            .reply(
                200, "{\"object\":\"list\",\"data\":[],\"has_more\":false,\"next_cursor\":null}");
    stub.client()
        .api()
        .listWaitpoints(
            new ListWaitpointsParams().state("open").awaitingResponse(true).limit(10),
            RequestOptions.none());

    assertEquals(
        "https://relay.example.com/v1/waitpoints?state=open&awaiting_response=true&limit=10",
        stub.requests.get(0).uri().toString());
  }

  @Test
  @DisplayName("API-2: a required If-Match is checked before sending")
  void requiredIfMatch() {
    Stub stub = new Stub();
    RelayClient client = stub.client();
    RequestOptions none = RequestOptions.none();
    assertThrows(
        IllegalArgumentException.class,
        () ->
            client
                .requester()
                .execute(
                    new Operation(
                        "op",
                        "PUT",
                        "/v1/x",
                        Operation.Presence.REQUIRED,
                        Operation.Presence.REQUIRED,
                        Operation.Presence.REQUIRED,
                        "application/json",
                        Operation.Response.JSON),
                    List.of(),
                    java.util.Map.of(),
                    Json.object(),
                    none));
    assertTrue(stub.requests.isEmpty());
  }
}
