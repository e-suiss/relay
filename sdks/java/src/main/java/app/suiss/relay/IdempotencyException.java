package app.suiss.relay;

/** The idempotency key was missing, not valid, reused or still in progress. */
public final class IdempotencyException extends ApiException {
  private static final long serialVersionUID = 1L;

  IdempotencyException(Problem problem) {
    super(problem);
  }
}
