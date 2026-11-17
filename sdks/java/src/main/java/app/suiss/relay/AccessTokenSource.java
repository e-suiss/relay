package app.suiss.relay;

import com.fasterxml.jackson.databind.JsonNode;
import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Random;

/**
 * Obtains DPoP-bound access tokens from Access with OAuth 2.0 client credentials and keeps each
 * one until shortly before it expires.
 */
public final class AccessTokenSource implements TokenSource {
  private static final Duration SKEW = Duration.ofSeconds(30);

  private final URI tokenEndpoint;
  private final String clientId;
  private final String clientSecret;
  private final String resource;
  private final String scope;
  private final DpopKey key;
  private final Transport transport;
  private final Clock clock;
  private final Random random;
  private String token;
  private Instant expiresAt = Instant.MIN;

  private AccessTokenSource(Builder builder) {
    this.tokenEndpoint = Objects.requireNonNull(builder.tokenEndpoint, "tokenEndpoint");
    this.clientId = Objects.requireNonNull(builder.clientId, "clientId");
    this.clientSecret = Objects.requireNonNull(builder.clientSecret, "clientSecret");
    this.resource = Objects.requireNonNull(builder.resource, "resource");
    this.scope = builder.scope;
    this.key = Objects.requireNonNull(builder.key, "key");
    this.transport = builder.transport == null ? new JdkTransport() : builder.transport;
    this.clock = builder.clock == null ? Clock.systemUTC() : builder.clock;
    this.random = builder.random == null ? new SecureRandom() : builder.random;
  }

  /**
   * Starts a token source.
   *
   * @return a builder
   */
  public static Builder builder() {
    return new Builder();
  }

  @Override
  public synchronized String accessToken() throws IOException {
    if (token != null && clock.instant().isBefore(expiresAt)) {
      return token;
    }
    return fetch(null, true);
  }

  private String fetch(String nonce, boolean nonceRetry) throws IOException {
    Map<String, String> form = new LinkedHashMap<>();
    form.put("grant_type", "client_credentials");
    form.put("resource", resource);
    if (scope != null) {
      form.put("scope", scope);
    }
    byte[] jti = new byte[16];
    random.nextBytes(jti);
    Map<String, List<String>> headers = new LinkedHashMap<>();
    headers.put("Accept", List.of("application/json"));
    headers.put("Content-Type", List.of("application/x-www-form-urlencoded"));
    headers.put("Authorization", List.of("Basic " + basic()));
    headers.put("DPoP", List.of(key.proof("POST", tokenEndpoint, null, nonce, clock.instant(), jti)));
    Transport.Response response =
        transport.send(
            new Transport.Request(
                "POST",
                tokenEndpoint,
                headers,
                encode(form).getBytes(StandardCharsets.UTF_8),
                Duration.ofSeconds(30)));
    JsonNode body = Json.parseOrMissing(response.body());
    if (response.status() == 200) {
      return issued(body);
    }
    String error = body.path("error").asText("");
    String serverNonce = response.header("DPoP-Nonce");
    if (response.status() == 400
        && error.equals("use_dpop_nonce")
        && nonceRetry
        && serverNonce != null
        && !serverNonce.isEmpty()) {
      return fetch(serverNonce, false);
    }
    String code = error.isEmpty() ? "access_token_refused" : "access_" + error;
    throw new AuthenticationException(
        Problem.local(response.status(), code, body.path("error_description").asText(null)));
  }

  private String issued(JsonNode body) {
    String accessToken = body.path("access_token").asText("");
    String type = body.path("token_type").asText("");
    if (accessToken.isEmpty() || !type.equalsIgnoreCase("DPoP")) {
      throw new AuthenticationException(
          Problem.local(200, "access_token_refused", "Access did not issue a DPoP access token"));
    }
    long lifetime = body.path("expires_in").canConvertToLong() ? body.path("expires_in").asLong() : 300;
    this.token = accessToken;
    this.expiresAt = clock.instant().plus(Duration.ofSeconds(lifetime)).minus(SKEW);
    return accessToken;
  }

  private String basic() {
    String pair =
        URLEncoder.encode(clientId, StandardCharsets.UTF_8)
            + ":"
            + URLEncoder.encode(clientSecret, StandardCharsets.UTF_8);
    return Base64.getEncoder().encodeToString(pair.getBytes(StandardCharsets.UTF_8));
  }

  private static String encode(Map<String, String> form) {
    StringBuilder out = new StringBuilder();
    for (Map.Entry<String, String> entry : form.entrySet()) {
      if (out.length() > 0) {
        out.append('&');
      }
      out.append(URLEncoder.encode(entry.getKey(), StandardCharsets.UTF_8))
          .append('=')
          .append(URLEncoder.encode(entry.getValue(), StandardCharsets.UTF_8));
    }
    return out.toString();
  }

  /** Builds an {@link AccessTokenSource}. */
  public static final class Builder {
    private URI tokenEndpoint;
    private String clientId;
    private String clientSecret;
    private String resource;
    private String scope;
    private DpopKey key;
    private Transport transport;
    private Clock clock;
    private Random random;

    private Builder() {}

    /**
     * The token endpoint of the Access issuer.
     *
     * @param value the HTTPS token endpoint
     * @return this builder
     */
    public Builder tokenEndpoint(URI value) {
      this.tokenEndpoint = value;
      return this;
    }

    /**
     * The API client's Access client identifier.
     *
     * @param value the client id
     * @return this builder
     */
    public Builder clientId(String value) {
      this.clientId = value;
      return this;
    }

    /**
     * The API client's Access client secret, sent with HTTP Basic authentication.
     *
     * @param value the client secret
     * @return this builder
     */
    public Builder clientSecret(String value) {
      this.clientSecret = value;
      return this;
    }

    /**
     * Relay's Access client identifier, {@code access_client_id} in Relay's discovery document.
     *
     * @param value the resource indicator
     * @return this builder
     */
    public Builder resource(String value) {
      this.resource = value;
      return this;
    }

    /**
     * Narrows the token to these space-separated scopes.
     *
     * @param value the scopes, or null for every registered scope
     * @return this builder
     */
    public Builder scope(String value) {
      this.scope = value;
      return this;
    }

    /**
     * The key the tokens are bound to; the same key signs every request proof.
     *
     * @param value the key
     * @return this builder
     */
    public Builder key(DpopKey value) {
      this.key = value;
      return this;
    }

    /**
     * The transport for token requests.
     *
     * @param value the transport
     * @return this builder
     */
    public Builder transport(Transport value) {
      this.transport = value;
      return this;
    }

    /**
     * The clock for token lifetimes and proof times.
     *
     * @param value the clock
     * @return this builder
     */
    public Builder clock(Clock value) {
      this.clock = value;
      return this;
    }

    /**
     * The random source for proof identifiers.
     *
     * @param value the random source
     * @return this builder
     */
    public Builder random(Random value) {
      this.random = value;
      return this;
    }

    /**
     * Builds the token source.
     *
     * @return the token source
     */
    public AccessTokenSource build() {
      return new AccessTokenSource(this);
    }
  }
}
