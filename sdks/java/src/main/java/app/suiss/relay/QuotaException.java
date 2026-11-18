package app.suiss.relay;

/** The sending quota is exhausted; retrying does not help ({@code quota_exhausted}). */
public final class QuotaException extends RateLimitException {
  private static final long serialVersionUID = 1L;

  QuotaException(Problem problem) {
    super(problem);
  }
}
