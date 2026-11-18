package app.suiss.relay;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.MissingNode;
import java.time.Duration;
import java.time.Instant;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;

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

  static Problem of(Transport.Response response, Instant now) {
    JsonNode parsed = Json.parseOrMissing(response.body());
    JsonNode body = parsed.isObject() ? parsed : MissingNode.getInstance();
    String code = text(body, "code");
    Duration retryAfter = retryAfter(response.header("Retry-After"), now);
    JsonNode member = body.path("retry_after");
    if (retryAfter == null && member.canConvertToLong() && member.asLong() >= 0) {
      retryAfter = Duration.ofSeconds(member.asLong());
    }
    JsonNode flag = body.path("retryable");
    boolean retryable =
        flag.isBoolean() ? flag.booleanValue() : defaultRetryable(response.status(), code);
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

  static boolean defaultRetryable(int status, String code) {
    if (code != null) {
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
    return false;
  }

  static Duration retryAfter(String header, Instant now) {
    if (header == null) {
      return null;
    }
    String value = header.trim();
    if (!value.isEmpty() && value.length() <= 9 && value.chars().allMatch(Character::isDigit)) {
      return Duration.ofSeconds(Long.parseLong(value));
    }
    try {
      Instant at = ZonedDateTime.parse(value, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant();
      return at.isAfter(now) ? Duration.between(now, at) : Duration.ZERO;
    } catch (DateTimeParseException e) {
      return null;
    }
  }

  String family() {
    ErrorCatalog.Entry entry = code == null ? null : ErrorCatalog.CODES.get(code);
    return entry == null ? null : entry.family();
  }

  String errorClass() {
    String family = family();
    if (family == null) {
      if (status == 401 || status == 403) {
        return "auth";
      }
      if (status == 429) {
        return "rate_limit";
      }
      return status >= 500 ? "server" : "validation";
    }
    return switch (family) {
      case "auth" -> "auth";
      case "quota" -> "rate_limit";
      case "idempotency" -> "idempotency";
      case "platform" -> "server";
      default -> status >= 500 ? "server" : "validation";
    };
  }

  ApiException toException() {
    return switch (errorClass()) {
      case "auth" -> new AuthenticationException(this);
      case "rate_limit" ->
          code == null || code.equals("rate_limited") || family() == null
              ? new RateLimitException(this)
              : new QuotaException(this);
      case "idempotency" -> new IdempotencyException(this);
      case "server" -> new ServerException(this);
      default ->
          switch (status) {
            case 404 -> new NotFoundException(this);
            case 409, 412, 428 -> new ConflictException(this);
            default -> new ValidationException(this);
          };
    };
  }

  private static String text(JsonNode body, String field) {
    JsonNode node = body.path(field);
    return node.isTextual() ? node.textValue() : null;
  }
}
