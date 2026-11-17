package app.suiss.relay;

import app.suiss.relay.params.ListMailboxRecordsParams;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Iterator;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.function.Consumer;

/** Waitpoint and mailbox helpers for agents and the API clients that wait on them. */
public final class Agents {
  private static final Set<String> WAITING = Set.of("open", "stalled");

  private final RelayApi api;
  private final Sleeper sleeper;
  private final Clock clock;

  Agents(RelayApi api, Sleeper sleeper, Clock clock) {
    this.api = api;
    this.sleeper = sleeper;
    this.clock = clock;
  }

  /**
   * Opens a waitpoint. The idempotency key is the waitpoint's identity, so pass your own key in
   * {@code options} to make a repeated call return the same waitpoint.
   *
   * @param body the waitpoint
   * @param options the request options
   * @return the waitpoint
   */
  public JsonNode createWaitpoint(JsonNode body, RequestOptions options) {
    return api.createWaitpoint(body, options);
  }

  /**
   * Polls a waitpoint until it is no longer open or stalled.
   *
   * @param waitpointId the waitpoint
   * @param timeout how long to wait
   * @param pollInterval the time between reads
   * @return the resolved, expired or cancelled waitpoint
   * @throws WaitpointTimeoutException when the waitpoint still waits after the timeout
   */
  public JsonNode awaitWaitpoint(String waitpointId, Duration timeout, Duration pollInterval) {
    Instant deadline = clock.instant().plus(timeout);
    while (true) {
      JsonNode waitpoint = api.getWaitpoint(waitpointId);
      if (!WAITING.contains(waitpoint.path("state").asText(""))) {
        return waitpoint;
      }
      Instant now = clock.instant();
      if (!now.isBefore(deadline)) {
        throw new WaitpointTimeoutException(waitpointId, waitpoint);
      }
      Duration left = Duration.between(now, deadline);
      try {
        sleeper.sleep(left.compareTo(pollInterval) < 0 ? left : pollInterval);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new ConnectionException("interrupted while waiting for " + waitpointId, e);
      }
    }
  }

  /**
   * Takes at most {@code max} records of the caller's mailbox with a lease.
   *
   * @param max the number of records
   * @return the lease and its records
   */
  public JsonNode leaseMailbox(int max) {
    ObjectNode body = Json.object();
    body.put("max", max);
    return api.leaseMailboxRecords(body, RequestOptions.none());
  }

  /**
   * Acknowledges records of one lease.
   *
   * @param leaseId the lease
   * @param recordIds the records
   * @return the result for each record
   */
  public JsonNode ackMailbox(String leaseId, List<String> recordIds) {
    ObjectNode body = Json.object();
    body.put("lease_id", leaseId);
    ArrayNode ids = body.putArray("record_ids");
    recordIds.forEach(ids::add);
    return api.ackMailboxRecords(body);
  }

  /**
   * Reads mailbox records after a position without taking a lease.
   *
   * @param since the position, or null for the acknowledged position
   * @return the records, the cursor to continue from and {@code has_more}
   */
  public JsonNode readMailbox(String since) {
    ListMailboxRecordsParams params = new ListMailboxRecordsParams().limit(100);
    if (since != null) {
      params.since(since);
    }
    return api.listMailboxRecords(params, RequestOptions.none());
  }

  /**
   * A mailbox reader that hands every record to {@code handler} once.
   *
   * @param handler receives each record
   * @return the feed
   */
  public MailboxFeed mailboxFeed(Consumer<JsonNode> handler) {
    return new MailboxFeed(this, handler, MailboxFeed.DEFAULT_CAPACITY);
  }

  /**
   * Opens the hint stream first, then reads the mailbox history, then reads again after every hint,
   * and hands each record to {@code handler} once by its id. A hint is only a wake-up: its content
   * is not used.
   *
   * @param hints the wake hints, for example webhook or push deliveries
   * @param handler receives each record
   * @param <H> the hint type
   */
  public <H> void follow(Iterable<H> hints, Consumer<JsonNode> handler) {
    Objects.requireNonNull(handler, "handler");
    Iterator<H> stream = hints.iterator();
    MailboxFeed feed = mailboxFeed(handler);
    feed.catchUp();
    while (stream.hasNext()) {
      stream.next();
      feed.catchUp();
    }
  }
}
