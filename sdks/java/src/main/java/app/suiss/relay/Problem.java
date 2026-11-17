package app.suiss.relay;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.MissingNode;
import java.time.Duration;

record Problem(
    int status,
    String code,
    String title,
    String detail,
    String type,
    String requestId,
    boolean retryable,
    Duration retryAfter,
    JsonNode body) {

  static Problem of(Transport.Response response) {
    JsonNode body = Json.parseOrMissing(response.body());
    String code = text(body, "code");
    Duration retryAfter = retryAfter(response.header("Retry-After"));
    if (retryAfter == null && body.path("retry_after").canConvertToLong()) {
      retryAfter = Duration.ofSeconds(Math.max(0, body.path("retry_after").asLong()));
    }
    JsonNode flag = body.path("retryable");
    boolean retryable =
        flag.isBoolean() ? flag.booleanValue() : catalogRetryable(response.status(), code);
    String requestId = text(body, "request_id");
    if (requestId == null) {
      requestId = response.header("Request-Id");
    }
    return new Problem(
        response.status(),
        code,
        text(body, "title"),
        text(body, "detail"),
        text(body, "type"),
        requestId,
        retryable,
        retryAfter,
        body);
  }

  static Problem local(int status, String code, String detail) {
    return new Problem(
        status, code, code, detail, null, null, false, null, MissingNode.getInstance());
  }

  static boolean catalogRetryable(int status, String code) {
    if (code != null) {
      ErrorCatalog.Entry entry = ErrorCatalog.CODES.get(code);
      if (entry != null) {
        return entry.retryable();
      }
      for (ErrorCatalog.Default d : ErrorCatalog.DEFAULTS) {
        if (d.status() == status && code.equals(d.code())) {
          return d.retryable();
        }
      }
    }
    for (ErrorCatalog.Default d : ErrorCatalog.DEFAULTS) {
      if (d.status() == status && d.code() == null) {
        return d.retryable();
      }
    }
    return status >= 500;
  }

  static Duration retryAfter(String header) {
    if (header == null) {
      return null;
    }
    String value = header.trim();
    if (value.isEmpty() || value.length() > 9 || !value.chars().allMatch(Character::isDigit)) {
      return null;
    }
    return Duration.ofSeconds(Long.parseLong(value));
  }

  String family() {
    ErrorCatalog.Entry entry = code == null ? null : ErrorCatalog.CODES.get(code);
    return entry == null ? null : entry.family();
  }

  ApiException toException() {
    String family = family();
    if ("idempotency".equals(family) || (code != null && code.startsWith("idempotency_"))) {
      return new IdempotencyException(this);
    }
    if (status >= 500) {
      return new ServerException(this);
    }
    if (status == 429) {
      return "quota_exhausted".equals(code)
          ? new QuotaException(this)
          : new RateLimitException(this);
    }
    if (status == 401 || "auth".equals(family)) {
      return new AuthenticationException(this);
    }
    return switch (status) {
      case 404 -> new NotFoundException(this);
      case 409, 412, 428 -> new ConflictException(this);
      case 400, 413, 415, 422 -> new ValidationException(this);
      default -> new ApiException(this);
    };
  }

  private static String text(JsonNode body, String field) {
    JsonNode node = body.path(field);
    return node.isTextual() ? node.textValue() : null;
  }
}
