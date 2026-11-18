package app.suiss.relay;

/** The request was refused by a rate or quota limit (429). */
public class RateLimitException extends ApiException {
  private static final long serialVersionUID = 1L;

  RateLimitException(Problem problem) {
    super(problem);
  }
}
