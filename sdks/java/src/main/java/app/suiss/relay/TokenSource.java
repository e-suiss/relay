package app.suiss.relay;

import java.io.IOException;

/** Supplies the DPoP-bound Access access token for requests. */
@FunctionalInterface
public interface TokenSource {
  /**
   * Returns a token that is valid now.
   *
   * @return the access token
   * @throws IOException when the token cannot be obtained
   */
  String accessToken() throws IOException;
}
