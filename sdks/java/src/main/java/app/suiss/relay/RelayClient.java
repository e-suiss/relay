package app.suiss.relay;

import java.net.URI;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Duration;
import java.util.Objects;
import java.util.Random;

/**
 * The Relay server API client. It pins every request to {@link ApiVersion#VALUE}, sends an
 * idempotency key with every mutating request and reuses it on retries, and retries only errors
 * Relay marks retryable, with exponential backoff, full jitter and {@code Retry-After}.
 *
 * <pre>{@code
 * DpopKey key = DpopKey.generate();
 * RelayClient relay = RelayClient.builder()
 *     .baseUrl("https://relay.example.com")
 *     .credentials(DpopCredentials.of(key, AccessTokenSource.builder()
 *         .tokenEndpoint(URI.create("https://access.example.com/oauth2/token"))
 *         .clientId("...").clientSecret("...").resource("...").key(key).build()))
 *     .build();
 * relay.api().createEvent(event);
 * }</pre>
 */
public final class RelayClient {
  /** The version of this SDK. */
  public static final String SDK_VERSION = "0.1.0";

  private final Requester requester;
  private final RelayApi api;
  private final Agents agents;

  private RelayClient(Requester requester) {
    this.requester = requester;
    this.api = new RelayApi(requester);
    this.agents = new Agents(api, requester.settings().sleeper(), requester.settings().clock());
  }

  /**
   * Starts a client.
   *
   * @return a builder
   */
  public static Builder builder() {
    return new Builder();
  }

  /**
   * Every operation of the server API.
   *
   * @return the API
   */
  public RelayApi api() {
    return api;
  }

  /**
   * Helpers for waitpoints and the mailbox.
   *
   * @return the agent helpers
   */
  public Agents agents() {
    return agents;
  }

  Requester requester() {
    return requester;
  }

  /** Builds a {@link RelayClient}. */
  public static final class Builder {
    private URI baseUri;
    private DpopCredentials credentials;
    private Transport transport;
    private Sleeper sleeper = Sleeper.SYSTEM;
    private Clock clock = Clock.systemUTC();
    private Random random;
    private int maxRetries = 3;
    private Duration baseDelay = Duration.ofMillis(500);
    private Duration maxDelay = Duration.ofSeconds(8);
    private Duration maxRetryAfter = Duration.ofSeconds(60);
    private Duration timeout = Duration.ofSeconds(30);

    private Builder() {}

    /**
     * The base address of the data region.
     *
     * @param value an HTTPS URL such as {@code https://relay.example.com}
     * @return this builder
     */
    public Builder baseUrl(String value) {
      return baseUrl(URI.create(value));
    }

    /**
     * The base address of the data region.
     *
     * @param value an HTTPS URL
     * @return this builder
     */
    public Builder baseUrl(URI value) {
      this.baseUri = value;
      return this;
    }

    /**
     * The credentials every request is signed with.
     *
     * @param value the credentials
     * @return this builder
     */
    public Builder credentials(DpopCredentials value) {
      this.credentials = value;
      return this;
    }

    /**
     * The HTTP transport; {@link JdkTransport} by default.
     *
     * @param value the transport
     * @return this builder
     */
    public Builder transport(Transport value) {
      this.transport = value;
      return this;
    }

    /**
     * How many times a retryable failure is retried; 3 by default, 0 turns retries off.
     *
     * @param value the retry count
     * @return this builder
     */
    public Builder maxRetries(int value) {
      if (value < 0) {
        throw new IllegalArgumentException("maxRetries must not be negative");
      }
      this.maxRetries = value;
      return this;
    }

    /**
     * The first backoff ceiling; it doubles on every retry up to {@link #maxDelay(Duration)}.
     *
     * @param value the base delay
     * @return this builder
     */
    public Builder baseDelay(Duration value) {
      this.baseDelay = value;
      return this;
    }

    /**
     * The largest backoff ceiling.
     *
     * @param value the cap
     * @return this builder
     */
    public Builder maxDelay(Duration value) {
      this.maxDelay = value;
      return this;
    }

    /**
     * The longest {@code Retry-After} the client waits; a longer one ends the call with the error.
     *
     * @param value the limit
     * @return this builder
     */
    public Builder maxRetryAfter(Duration value) {
      this.maxRetryAfter = value;
      return this;
    }

    /**
     * The time allowed for each response.
     *
     * @param value the timeout
     * @return this builder
     */
    public Builder timeout(Duration value) {
      this.timeout = value;
      return this;
    }

    /**
     * The sleeper for retry and poll waits.
     *
     * @param value the sleeper
     * @return this builder
     */
    public Builder sleeper(Sleeper value) {
      this.sleeper = value;
      return this;
    }

    /**
     * The clock for proof times and waits.
     *
     * @param value the clock
     * @return this builder
     */
    public Builder clock(Clock value) {
      this.clock = value;
      return this;
    }

    /**
     * The random source for jitter, proof identifiers and idempotency keys.
     *
     * @param value the random source
     * @return this builder
     */
    public Builder random(Random value) {
      this.random = value;
      return this;
    }

    /**
     * Builds the client.
     *
     * @return the client
     */
    public RelayClient build() {
      Objects.requireNonNull(baseUri, "baseUrl");
      Objects.requireNonNull(credentials, "credentials");
      return new RelayClient(
          new Requester(
              new Requester.Settings(
                  baseUri,
                  credentials,
                  transport == null ? new JdkTransport() : transport,
                  sleeper,
                  clock,
                  random == null ? new SecureRandom() : random,
                  maxRetries,
                  baseDelay,
                  maxDelay,
                  maxRetryAfter,
                  timeout,
                  "esuiss-relay-java/" + SDK_VERSION + " (api " + ApiVersion.VALUE + ")")));
    }
  }
}
