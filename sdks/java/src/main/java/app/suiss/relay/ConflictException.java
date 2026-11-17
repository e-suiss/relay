package app.suiss.relay;

/** The request conflicts with the current state of the resource (409, 412, 428). */
public final class ConflictException extends ApiException {
  private static final long serialVersionUID = 1L;

  ConflictException(Problem problem) {
    super(problem);
  }
}
