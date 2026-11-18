package app.suiss.relay;

/** The request was refused as it stands (400, 413, 415, 422). */
public class ValidationException extends ApiException {
  private static final long serialVersionUID = 1L;

  ValidationException(Problem problem) {
    super(problem);
  }
}
