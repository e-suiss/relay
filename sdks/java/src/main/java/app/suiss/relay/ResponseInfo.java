package app.suiss.relay;

import java.util.List;
import java.util.Map;

/**
 * The status and headers of a successful response.
 *
 * @param status the HTTP status
 * @param headers the response headers
 * @param replayed whether Relay replayed the first response to this idempotency key
 * @param requestId the {@code Request-Id}, or null
 */
public record ResponseInfo(
    int status, Map<String, List<String>> headers, boolean replayed, String requestId) {

  static ResponseInfo of(Transport.Response response) {
    return new ResponseInfo(
        response.status(),
        response.headers(),
        "true".equalsIgnoreCase(response.header("Idempotency-Replayed")),
        response.header("Request-Id"));
  }
}
