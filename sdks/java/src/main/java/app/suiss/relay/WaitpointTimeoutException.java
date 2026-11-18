package app.suiss.relay;

import com.fasterxml.jackson.databind.JsonNode;

/** A waitpoint was still open or stalled when the wait ended. */
public final class WaitpointTimeoutException extends RelayException {
  private static final long serialVersionUID = 1L;

  private final String waitpointId;
  private final transient JsonNode waitpoint;

  WaitpointTimeoutException(String waitpointId, JsonNode waitpoint) {
    super(waitpointId + " is still waiting", null);
    this.waitpointId = waitpointId;
    this.waitpoint = waitpoint;
  }

  /**
   * The waitpoint that is still waiting.
   *
   * @return the waitpoint id
   */
  public String waitpointId() {
    return waitpointId;
  }

  /**
   * The waitpoint as it was last read.
   *
   * @return the waitpoint
   */
  public JsonNode waitpoint() {
    return waitpoint;
  }
}
