package app.suiss.relay;

/** A webhook did not verify. Answer it with a 4xx status and do not act on its body. */
public final class WebhookVerificationException extends RelayException {
  private static final long serialVersionUID = 1L;

  /** Why a webhook was refused. */
  public enum Reason {
    /** A signed header is missing. */
    MISSING_HEADER,
    /** A signed header appears more than once. */
    DUPLICATE_HEADER,
    /** A signed header is not well formed. */
    MALFORMED_HEADER,
    /** {@code webhook-timestamp} is outside the tolerance, in either direction. */
    TIMESTAMP_OUT_OF_TOLERANCE,
    /** No signature verifies with any of the keys. */
    NO_MATCHING_SIGNATURE
  }

  private final Reason reason;

  WebhookVerificationException(Reason reason) {
    super("webhook refused: " + reason.name().toLowerCase(java.util.Locale.ROOT), null);
    this.reason = reason;
  }

  /**
   * Why the webhook was refused.
   *
   * @return the reason
   */
  public Reason reason() {
    return reason;
  }
}
