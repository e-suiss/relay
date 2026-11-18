package app.suiss.relay;

/**
 * A webhook that verified.
 *
 * @param id the {@code webhook-id}, the same for every attempt of one event
 * @param timestamp the {@code webhook-timestamp} in Unix seconds
 * @param scheme the scheme of the signature that verified: {@code v1a} or {@code v1}
 */
public record VerifiedWebhook(String id, long timestamp, String scheme) {}
