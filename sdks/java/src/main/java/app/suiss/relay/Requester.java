package app.suiss.relay;

import app.suiss.relay.params.QueryParams;
import com.fasterxml.jackson.databind.JsonNode;
import java.io.IOException;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.UUID;

final class Requester {
  record Settings(
      URI baseUri,
      DpopCredentials credentials,
      Transport transport,
      Sleeper sleeper,
      Clock clock,
      Random random,
      int maxRetries,
      Duration baseDelay,
      Duration maxDelay,
      Duration maxRetryAfter,
      Duration timeout,
      String userAgent) {}

  private final Settings settings;

  Requester(Settings settings) {
    this.settings = settings;
  }

  Settings settings() {
    return settings;
  }

  JsonNode json(
      Operation op,
      List<String> path,
      QueryParams<?> params,
      JsonNode body,
      RequestOptions options) {
    return Json.parse(execute(op, path, query(params), body, options).body());
  }

  String text(
      Operation op,
      List<String> path,
      QueryParams<?> params,
      JsonNode body,
      RequestOptions options) {
    byte[] bytes = execute(op, path, query(params), body, options).body();
    return bytes == null ? "" : new String(bytes, StandardCharsets.UTF_8);
  }

  Page page(Operation op, List<String> path, QueryParams<?> params, RequestOptions options) {
    return page(op, path, query(params), options);
  }

  private Page page(
      Operation op, List<String> path, Map<String, String> query, RequestOptions options) {
    JsonNode raw = Json.parse(execute(op, path, query, null, options).body());
    return new Page(
        raw,
        cursor -> {
          Map<String, String> next = new LinkedHashMap<>(query);
          next.remove("ending_before");
          next.put("starting_after", cursor);
          return page(op, path, next, options);
        });
  }

  private static Map<String, String> query(QueryParams<?> params) {
    return params == null ? Map.of() : params.values();
  }

  Transport.Response execute(
      Operation op,
      List<String> path,
      Map<String, String> query,
      JsonNode body,
      RequestOptions options) {
    RequestOptions o = options == null ? RequestOptions.none() : options;
    if (op.ifMatch() == Operation.Presence.REQUIRED && o.ifMatch() == null) {
      throw new IllegalArgumentException(op.id() + " needs RequestOptions.ifMatch");
    }
    if (op.body() == Operation.Presence.REQUIRED && body == null) {
      throw new IllegalArgumentException(op.id() + " needs a request body");
    }
    URI uri = Urls.build(settings.baseUri(), op.path(), path, query);
    byte[] payload = body == null ? null : Json.write(body);
    String key = null;
    if (op.idempotency() != Operation.Presence.NONE) {
      key = o.idempotencyKey() != null ? o.idempotencyKey() : newIdempotencyKey();
    }
    boolean replayable = op.method().equals("GET") || key != null;
    for (int attempt = 0; ; attempt++) {
      Transport.Response response;
      try {
        response =
            settings
                .transport()
                .send(
                    new Transport.Request(
                        op.method(),
                        uri,
                        headers(op, uri, key, o, payload != null),
                        payload,
                        settings.timeout()));
      } catch (IOException e) {
        if (replayable && attempt < settings.maxRetries()) {
          pause(backoff(attempt));
          continue;
        }
        throw new ConnectionException(op.id() + " got no response: " + e.getMessage(), e);
      }
      if (response.status() < 400) {
        return response;
      }
      Problem problem = Problem.of(response);
      if (problem.retryable() && attempt < settings.maxRetries()) {
        Duration delay = delay(attempt, problem.retryAfter());
        if (delay != null) {
          pause(delay);
          continue;
        }
      }
      throw problem.toException();
    }
  }

  Duration delay(int attempt, Duration retryAfter) {
    if (retryAfter == null) {
      return backoff(attempt);
    }
    return retryAfter.compareTo(settings.maxRetryAfter()) > 0 ? null : retryAfter;
  }

  Duration backoff(int attempt) {
    long base = settings.baseDelay().toMillis();
    long cap = settings.maxDelay().toMillis();
    long ceiling = attempt >= 30 ? cap : Math.min(cap, base << attempt);
    return Duration.ofMillis((long) Math.floor(settings.random().nextDouble() * ceiling));
  }

  private void pause(Duration delay) {
    try {
      settings.sleeper().sleep(delay);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new ConnectionException("interrupted while waiting to retry", e);
    }
  }

  private Map<String, List<String>> headers(
      Operation op, URI uri, String key, RequestOptions o, boolean hasBody) {
    Map<String, List<String>> headers = new LinkedHashMap<>();
    headers.put("Accept", List.of("application/json"));
    headers.put("User-Agent", List.of(settings.userAgent()));
    headers.put("Relay-Version", List.of(ApiVersion.VALUE));
    byte[] jti = new byte[16];
    settings.random().nextBytes(jti);
    try {
      String[] auth =
          settings.credentials().headers(op.method(), uri, settings.clock().instant(), jti);
      headers.put("Authorization", List.of(auth[0]));
      headers.put("DPoP", List.of(auth[1]));
    } catch (IOException e) {
      throw new ConnectionException("the access token cannot be obtained: " + e.getMessage(), e);
    }
    if (hasBody) {
      headers.put(
          "Content-Type", List.of(o.contentType() != null ? o.contentType() : op.contentType()));
    }
    if (key != null) {
      headers.put("Idempotency-Key", List.of(key));
    }
    if (o.ifMatch() != null) {
      headers.put("If-Match", List.of(o.ifMatch()));
    }
    if (o.beta() != null) {
      headers.put("Relay-Beta", List.of(o.beta()));
    }
    for (Map.Entry<String, String> extra : o.headers().entrySet()) {
      headers.put(extra.getKey(), List.of(extra.getValue()));
    }
    return headers;
  }

  private String newIdempotencyKey() {
    byte[] bytes = new byte[16];
    settings.random().nextBytes(bytes);
    bytes[6] = (byte) ((bytes[6] & 0x0f) | 0x40);
    bytes[8] = (byte) ((bytes[8] & 0x3f) | 0x80);
    long high = 0;
    long low = 0;
    for (int i = 0; i < 8; i++) {
      high = (high << 8) | (bytes[i] & 0xff);
      low = (low << 8) | (bytes[i + 8] & 0xff);
    }
    return new UUID(high, low).toString();
  }
}
