package app.suiss.relay;

/** No response arrived: the connection failed, timed out or was interrupted. */
public final class ConnectionException extends RelayException {
  private static final long serialVersionUID = 1L;

  /**
   * Creates an exception.
   *
   * @param message the message
   * @param cause the cause
   */
  public ConnectionException(String message, Throwable cause) {
    super(message, cause);
  }
}
