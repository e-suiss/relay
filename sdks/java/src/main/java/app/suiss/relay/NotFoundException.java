package app.suiss.relay;

/** The resource does not exist in this tenant and environment (404). */
public final class NotFoundException extends ApiException {
  private static final long serialVersionUID = 1L;

  NotFoundException(Problem problem) {
    super(problem);
  }
}
