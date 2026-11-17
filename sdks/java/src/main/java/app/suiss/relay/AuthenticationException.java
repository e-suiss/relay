package app.suiss.relay;

/** The credentials were missing, not valid or lacked a scope (401, 403 and the {@code auth_*} codes). */
public final class AuthenticationException extends ApiException {
  private static final long serialVersionUID = 1L;

  AuthenticationException(Problem problem) {
    super(problem);
  }
}
