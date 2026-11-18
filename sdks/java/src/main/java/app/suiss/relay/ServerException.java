package app.suiss.relay;

/** Relay could not answer the request (5xx). */
public final class ServerException extends ApiException {
  private static final long serialVersionUID = 1L;

  ServerException(Problem problem) {
    super(problem);
  }
}
