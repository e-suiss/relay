package app.suiss.relay;

/** The base of every exception this SDK throws. */
public class RelayException extends RuntimeException {
  private static final long serialVersionUID = 1L;

  /**
   * Creates an exception.
   *
   * @param message the message
   * @param cause the cause, or null
   */
  public RelayException(String message, Throwable cause) {
    super(message, cause);
  }
}
