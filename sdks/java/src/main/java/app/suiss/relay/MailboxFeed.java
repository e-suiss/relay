package app.suiss.relay;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.function.Consumer;

/**
 * Reads the mailbox in stream order from where it last stopped and hands each record to its handler
 * once. Subscribe to wake hints first, call {@link #catchUp()} once for the history and again after
 * every hint.
 */
public final class MailboxFeed {
  static final int DEFAULT_CAPACITY = 10_000;

  private final Agents agents;
  private final Consumer<JsonNode> handler;
  private final Dedupe seen;
  private String cursor;

  MailboxFeed(Agents agents, Consumer<JsonNode> handler, int capacity) {
    this.agents = agents;
    this.handler = handler;
    this.seen = new Dedupe(capacity);
  }

  /**
   * Reads every record after the current position and hands the unseen ones to the handler.
   *
   * @return how many records reached the handler
   */
  public synchronized int catchUp() {
    int delivered = 0;
    boolean resynced = false;
    while (true) {
      JsonNode page = agents.readMailbox(cursor);
      JsonNode next = page.path("cursor");
      if (page.path("resync_required").asBoolean(false)) {
        if (resynced) {
          throw new RelayException("the mailbox asked for a resync twice in a row", null);
        }
        resynced = true;
        cursor = next.isTextual() ? next.textValue() : null;
        continue;
      }
      resynced = false;
      for (JsonNode record : page.path("records")) {
        if (seen.add(record.path("id").asText(""))) {
          handler.accept(record);
          delivered++;
        }
      }
      if (next.isTextual()) {
        cursor = next.textValue();
      }
      if (!page.path("has_more").asBoolean(false)) {
        return delivered;
      }
    }
  }

  /**
   * The position the next read starts after.
   *
   * @return the cursor, or null before the first read
   */
  public synchronized String cursor() {
    return cursor;
  }
}
