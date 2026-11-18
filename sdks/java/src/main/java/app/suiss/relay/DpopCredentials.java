package app.suiss.relay;

import java.io.IOException;
import java.net.URI;
import java.time.Instant;
import java.util.Objects;

/** An Access access token and the key it is bound to: {@code Authorization: DPoP} and a proof. */
public final class DpopCredentials {
  private final DpopKey key;
  private final TokenSource tokens;

  private DpopCredentials(DpopKey key, TokenSource tokens) {
    this.key = Objects.requireNonNull(key, "key");
    this.tokens = Objects.requireNonNull(tokens, "tokens");
  }

  /**
   * Credentials from a token source.
   *
   * @param key the key the tokens are bound to
   * @param tokens the token source, for example {@link AccessTokenSource}
   * @return the credentials
   */
  public static DpopCredentials of(DpopKey key, TokenSource tokens) {
    return new DpopCredentials(key, tokens);
  }

  /**
   * Credentials from a token obtained elsewhere.
   *
   * @param key the key the token is bound to
   * @param accessToken the access token
   * @return the credentials
   */
  public static DpopCredentials of(DpopKey key, String accessToken) {
    Objects.requireNonNull(accessToken, "accessToken");
    return new DpopCredentials(key, () -> accessToken);
  }

  /**
   * The key the tokens are bound to.
   *
   * @return the key
   */
  public DpopKey key() {
    return key;
  }

  String[] headers(String method, URI uri, Instant now, byte[] jti) throws IOException {
    String token = tokens.accessToken();
    return new String[] {"DPoP " + token, key.proof(method, uri, token, null, now, jti)};
  }
}
