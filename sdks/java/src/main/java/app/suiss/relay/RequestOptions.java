package app.suiss.relay;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/** Per-request options. Instances are immutable. */
public final class RequestOptions {
  private static final RequestOptions NONE = new Builder().build();

  private final String idempotencyKey;
  private final String ifMatch;
  private final String beta;
  private final String contentType;
  private final Map<String, String> headers;

  private RequestOptions(Builder builder) {
    this.idempotencyKey = builder.idempotencyKey;
    this.ifMatch = builder.ifMatch;
    this.beta = builder.beta;
    this.contentType = builder.contentType;
    this.headers = Collections.unmodifiableMap(new LinkedHashMap<>(builder.headers));
  }

  /**
   * Options that set nothing.
   *
   * @return the empty options
   */
  public static RequestOptions none() {
    return NONE;
  }

  /**
   * Starts a new set of options.
   *
   * @return a builder
   */
  public static Builder builder() {
    return new Builder();
  }

  /**
   * The idempotency key to send instead of a generated one.
   *
   * @return the key, or null
   */
  public String idempotencyKey() {
    return idempotencyKey;
  }

  /**
   * The {@code If-Match} value.
   *
   * @return the ETag, or null
   */
  public String ifMatch() {
    return ifMatch;
  }

  /**
   * The {@code Relay-Beta} value.
   *
   * @return the beta features, or null
   */
  public String beta() {
    return beta;
  }

  /**
   * The request content type to send instead of the operation's default.
   *
   * @return the content type, or null
   */
  public String contentType() {
    return contentType;
  }

  /**
   * Extra request headers.
   *
   * @return the headers
   */
  public Map<String, String> headers() {
    return headers;
  }

  /** Builds {@link RequestOptions}. */
  public static final class Builder {
    private String idempotencyKey;
    private String ifMatch;
    private String beta;
    private String contentType;
    private final Map<String, String> headers = new LinkedHashMap<>();

    private Builder() {}

    /**
     * Sends this idempotency key on every attempt instead of a generated one.
     *
     * @param value 8 to 255 characters, never derived from personal data
     * @return this builder
     */
    public Builder idempotencyKey(String value) {
      this.idempotencyKey = value;
      return this;
    }

    /**
     * Sets {@code If-Match}.
     *
     * @param value the ETag of the version being changed
     * @return this builder
     */
    public Builder ifMatch(String value) {
      this.ifMatch = value;
      return this;
    }

    /**
     * Sets {@code Relay-Beta}.
     *
     * @param value comma-separated beta features
     * @return this builder
     */
    public Builder beta(String value) {
      this.beta = value;
      return this;
    }

    /**
     * Sends the body with this content type, for example {@code application/cloudevents+json}.
     *
     * @param value the media type
     * @return this builder
     */
    public Builder contentType(String value) {
      this.contentType = value;
      return this;
    }

    /**
     * Adds a request header, for example {@code traceparent}.
     *
     * @param name the header name
     * @param value the header value
     * @return this builder
     */
    public Builder header(String name, String value) {
      this.headers.put(name, value);
      return this;
    }

    /**
     * Builds the options.
     *
     * @return the options
     */
    public RequestOptions build() {
      return new RequestOptions(this);
    }
  }
}
