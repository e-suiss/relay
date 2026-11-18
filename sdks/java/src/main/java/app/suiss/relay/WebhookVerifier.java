package app.suiss.relay;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.MessageDigest;
import java.security.PublicKey;
import java.security.Signature;
import java.security.spec.InvalidKeySpecException;
import java.security.spec.X509EncodedKeySpec;
import java.time.Clock;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * Verifies webhooks of the Suiss webhook profile, the Standard Webhooks headers shared by Relay and
 * Access: {@code v1a} Ed25519 signatures (the default) and {@code v1} HMAC-SHA256 signatures.
 *
 * <p>Pass the body exactly as it arrived, before any JSON parsing. Deduplicate verified messages by
 * {@code webhook-id} for at least 96 hours.
 *
 * <pre>{@code
 * WebhookVerifier verifier = WebhookVerifier.builder().key("whpk_...").build();
 * VerifiedWebhook webhook = verifier.verify(request.headers(), rawBody);
 * }</pre>
 */
public final class WebhookVerifier {
  /** The default tolerance between {@code webhook-timestamp} and the current time. */
  public static final Duration DEFAULT_TOLERANCE = Duration.ofMinutes(5);

  private static final Pattern ID = Pattern.compile("[\\x21-\\x7E]{1,256}");
  private static final Pattern TIMESTAMP = Pattern.compile("0|[1-9][0-9]{0,14}");
  private static final Pattern OTHER_SCHEME =
      Pattern.compile("v[0-9][0-9a-z]{0,7},[A-Za-z0-9+/=_-]+");
  private static final byte[] ED25519_PREFIX = {
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00
  };

  private record Key(PublicKey ed25519, byte[] hmac) {}

  private record Token(String scheme, byte[] signature) {}

  private final List<Key> keys;
  private final Duration tolerance;
  private final Clock clock;

  private WebhookVerifier(Builder builder) {
    if (builder.keys.isEmpty()) {
      throw new IllegalArgumentException("a webhook verifier needs at least one key");
    }
    this.keys = List.copyOf(builder.keys);
    this.tolerance = builder.tolerance;
    this.clock = builder.clock;
  }

  /**
   * Starts a verifier.
   *
   * @return a builder
   */
  public static Builder builder() {
    return new Builder();
  }

  /**
   * Verifies a webhook from its headers as they arrived.
   *
   * @param headers the request headers; names are matched without regard to case
   * @param rawBody the body bytes as they arrived
   * @return the verified message
   * @throws WebhookVerificationException when the webhook does not verify
   */
  public VerifiedWebhook verify(Map<String, ? extends List<String>> headers, byte[] rawBody) {
    return verify(
        single(headers, "webhook-id"),
        single(headers, "webhook-timestamp"),
        single(headers, "webhook-signature"),
        rawBody);
  }

  /**
   * Verifies a webhook from the values of its three signed headers.
   *
   * @param id the {@code webhook-id} value
   * @param timestamp the {@code webhook-timestamp} value
   * @param signature the {@code webhook-signature} value
   * @param rawBody the body bytes as they arrived
   * @return the verified message
   * @throws WebhookVerificationException when the webhook does not verify
   */
  public VerifiedWebhook verify(String id, String timestamp, String signature, byte[] rawBody) {
    if (id == null || timestamp == null || signature == null) {
      throw refused(WebhookVerificationException.Reason.MISSING_HEADER);
    }
    if (!ID.matcher(id).matches() || !TIMESTAMP.matcher(timestamp).matches()) {
      throw refused(WebhookVerificationException.Reason.MALFORMED_HEADER);
    }
    List<Token> tokens = tokens(signature);
    long seconds = Long.parseLong(timestamp);
    long now = clock.instant().getEpochSecond();
    if (Math.abs(now - seconds) > tolerance.getSeconds()) {
      throw refused(WebhookVerificationException.Reason.TIMESTAMP_OUT_OF_TOLERANCE);
    }
    byte[] content = signedContent(id, seconds, rawBody == null ? new byte[0] : rawBody);
    String scheme = null;
    for (Token token : tokens) {
      for (Key key : keys) {
        if (scheme == null && valid(token, key, content)) {
          scheme = token.scheme();
        }
      }
    }
    if (scheme == null) {
      throw refused(WebhookVerificationException.Reason.NO_MATCHING_SIGNATURE);
    }
    return new VerifiedWebhook(id, seconds, scheme);
  }

  static byte[] signedContent(String id, long timestamp, byte[] body) {
    byte[] prefix = (id + "." + timestamp + ".").getBytes(StandardCharsets.UTF_8);
    byte[] content = new byte[prefix.length + body.length];
    System.arraycopy(prefix, 0, content, 0, prefix.length);
    System.arraycopy(body, 0, content, prefix.length, body.length);
    return content;
  }

  private static String single(Map<String, ? extends List<String>> headers, String name) {
    List<String> values = Headers.all(headers, name);
    if (values.size() > 1) {
      throw refused(WebhookVerificationException.Reason.DUPLICATE_HEADER);
    }
    return values.isEmpty() ? null : values.get(0);
  }

  private static List<Token> tokens(String header) {
    List<Token> tokens = new ArrayList<>();
    boolean any = false;
    for (String part : header.split(" ")) {
      if (part.isEmpty()) {
        continue;
      }
      any = true;
      if (part.startsWith("v1a,")) {
        tokens.add(new Token("v1a", decode(part.substring(4), 64)));
      } else if (part.startsWith("v1,")) {
        tokens.add(new Token("v1", decode(part.substring(3), 32)));
      } else if (!OTHER_SCHEME.matcher(part).matches()) {
        throw refused(WebhookVerificationException.Reason.MALFORMED_HEADER);
      }
    }
    if (!any) {
      throw refused(WebhookVerificationException.Reason.MALFORMED_HEADER);
    }
    return tokens;
  }

  private static byte[] decode(String encoded, int size) {
    try {
      byte[] bytes = Base64.getDecoder().decode(encoded);
      if (bytes.length == size) {
        return bytes;
      }
    } catch (IllegalArgumentException e) {
      throw refused(WebhookVerificationException.Reason.MALFORMED_HEADER);
    }
    throw refused(WebhookVerificationException.Reason.MALFORMED_HEADER);
  }

  private static boolean valid(Token token, Key key, byte[] content) {
    try {
      if (token.scheme().equals("v1a") && key.ed25519() != null) {
        Signature verifier = Signature.getInstance("Ed25519");
        verifier.initVerify(key.ed25519());
        verifier.update(content);
        return verifier.verify(token.signature());
      }
      if (token.scheme().equals("v1") && key.hmac() != null) {
        return MessageDigest.isEqual(hmac(key.hmac(), content), token.signature());
      }
      return false;
    } catch (GeneralSecurityException e) {
      return false;
    }
  }

  static byte[] hmac(byte[] secret, byte[] content) throws GeneralSecurityException {
    Mac mac = Mac.getInstance("HmacSHA256");
    mac.init(new SecretKeySpec(secret, "HmacSHA256"));
    return mac.doFinal(content);
  }

  private static WebhookVerificationException refused(WebhookVerificationException.Reason reason) {
    return new WebhookVerificationException(reason);
  }

  static PublicKey ed25519(byte[] raw) throws GeneralSecurityException {
    byte[] der = new byte[ED25519_PREFIX.length + raw.length];
    System.arraycopy(ED25519_PREFIX, 0, der, 0, ED25519_PREFIX.length);
    System.arraycopy(raw, 0, der, ED25519_PREFIX.length, raw.length);
    return KeyFactory.getInstance("Ed25519").generatePublic(new X509EncodedKeySpec(der));
  }

  /** Builds a {@link WebhookVerifier}. */
  public static final class Builder {
    private final List<Key> keys = new ArrayList<>();
    private Duration tolerance = DEFAULT_TOLERANCE;
    private Clock clock = Clock.systemUTC();

    private Builder() {}

    /**
     * Adds a key that may have signed the webhooks: {@code whpk_<base64>} for an Ed25519 public key
     * or {@code whsec_<base64>} for an HMAC secret. Add both keys during a rotation.
     *
     * @param text the key in its text form
     * @return this builder
     */
    public Builder key(String text) {
      try {
        if (text.startsWith("whpk_")) {
          byte[] raw = Base64.getDecoder().decode(text.substring(5));
          if (raw.length != 32) {
            throw new IllegalArgumentException("an Ed25519 public key has 32 bytes");
          }
          keys.add(new Key(ed25519(raw), null));
        } else if (text.startsWith("whsec_")) {
          byte[] secret = Base64.getDecoder().decode(text.substring(6));
          if (secret.length < 24) {
            throw new IllegalArgumentException("an HMAC secret has at least 24 bytes");
          }
          keys.add(new Key(null, secret));
        } else {
          throw new IllegalArgumentException("a webhook key starts with whpk_ or whsec_");
        }
      } catch (InvalidKeySpecException e) {
        throw new IllegalArgumentException("the Ed25519 public key is not valid", e);
      } catch (GeneralSecurityException e) {
        throw new IllegalStateException("Ed25519 is not available", e);
      }
      return this;
    }

    /**
     * The largest distance between {@code webhook-timestamp} and now; 5 minutes by default.
     *
     * @param value the tolerance
     * @return this builder
     */
    public Builder tolerance(Duration value) {
      this.tolerance = value;
      return this;
    }

    /**
     * The clock the timestamp is compared with.
     *
     * @param value the clock
     * @return this builder
     */
    public Builder clock(Clock value) {
      this.clock = value;
      return this;
    }

    /**
     * Builds the verifier.
     *
     * @return the verifier
     */
    public WebhookVerifier build() {
      return new WebhookVerifier(this);
    }
  }
}
