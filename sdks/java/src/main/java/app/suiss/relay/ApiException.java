package app.suiss.relay;

import com.fasterxml.jackson.databind.JsonNode;
import java.time.Duration;

/** Relay answered with an RFC 9457 problem. Subclasses name the kind of error. */
public class ApiException extends RelayException {
  private static final long serialVersionUID = 1L;

  private final int status;
  private final String code;
  private final String title;
  private final String detail;
  private final String type;
  private final String requestId;
  private final boolean retryable;
  private final Duration retryAfter;
  private final transient JsonNode problem;

  ApiException(Problem problem) {
    super(message(problem), null);
    this.status = problem.status();
    this.code = problem.code();
    this.title = problem.title();
    this.detail = problem.detail();
    this.type = problem.type();
    this.requestId = problem.requestId();
    this.retryable = problem.retryable();
    this.retryAfter = problem.retryAfter();
    this.problem = problem.body();
  }

  private static String message(Problem problem) {
    StringBuilder out = new StringBuilder().append(problem.status());
    if (problem.code() != null) {
      out.append(' ').append(problem.code());
    }
    if (problem.detail() != null) {
      out.append(": ").append(problem.detail());
    } else if (problem.title() != null) {
      out.append(": ").append(problem.title());
    }
    return out.toString();
  }

  /**
   * The HTTP status.
   *
   * @return the status code
   */
  public int status() {
    return status;
  }

  /**
   * The error code, the last segment of {@code type}.
   *
   * @return the code, or null when the body was not a problem
   */
  public String code() {
    return code;
  }

  /**
   * The fixed title of the code.
   *
   * @return the title, or null
   */
  public String title() {
    return title;
  }

  /**
   * The explanation of this occurrence.
   *
   * @return the detail, or null
   */
  public String detail() {
    return detail;
  }

  /**
   * The resolvable URL of the error code page.
   *
   * @return the type, or null
   */
  public String type() {
    return type;
  }

  /**
   * The request identifier to quote to support.
   *
   * @return the request id, or null
   */
  public String requestId() {
    return requestId;
  }

  /**
   * Whether repeating the same request can succeed.
   *
   * @return the retryable flag
   */
  public boolean retryable() {
    return retryable;
  }

  /**
   * The wait Relay asked for before a retry.
   *
   * @return the delay, or null
   */
  public Duration retryAfter() {
    return retryAfter;
  }

  /**
   * The field errors of a validation problem, each with its {@code pointer}, {@code code} and
   * {@code detail}.
   *
   * @return the field errors, empty when there are none
   */
  public java.util.List<JsonNode> fieldErrors() {
    java.util.List<JsonNode> errors = new java.util.ArrayList<>();
    if (problem != null) {
      problem.path("errors").forEach(errors::add);
    }
    return errors;
  }

  /**
   * The whole problem body, with its extension members.
   *
   * @return the body, a missing node when it was not JSON
   */
  public JsonNode problem() {
    return problem;
  }
}
