package app.suiss.relay;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.fasterxml.jackson.databind.JsonNode;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

class AgentsTest {
  private static String waitpoint(String state) {
    return "{\"object\":\"waitpoint\",\"id\":\"wp_1\",\"state\":\"" + state + "\"}";
  }

  private static String records(String cursor, boolean hasMore, boolean resync, String... ids) {
    StringBuilder data = new StringBuilder();
    for (String id : ids) {
      if (data.length() > 0) {
        data.append(',');
      }
      data.append("{\"object\":\"mailbox_record\",\"id\":\"").append(id).append("\"}");
    }
    return "{\"object\":\"mailbox_records\",\"records\":["
        + data
        + "],\"cursor\":\""
        + cursor
        + "\",\"has_more\":"
        + hasMore
        + ",\"resync_required\":"
        + resync
        + "}";
  }

  @Test
  @DisplayName("X-30: await polls the waitpoint until it is no longer open or stalled")
  void awaitWaitpoint() {
    Stub stub =
        new Stub()
            .reply(200, waitpoint("open"))
            .reply(200, waitpoint("stalled"))
            .reply(200, waitpoint("resolved"));
    JsonNode resolved =
        stub.client()
            .agents()
            .awaitWaitpoint("wp_1", Duration.ofMinutes(1), Duration.ofSeconds(2));

    assertEquals("resolved", resolved.path("state").asText());
    assertEquals(List.of(Duration.ofSeconds(2), Duration.ofSeconds(2)), stub.sleeps);
  }

  @Test
  @DisplayName("X-30: await ends with the waitpoint when the time is up")
  void awaitTimeout() {
    Stub stub = new Stub().reply(200, waitpoint("open"));
    WaitpointTimeoutException error =
        assertThrows(
            WaitpointTimeoutException.class,
            () -> stub.client().agents().awaitWaitpoint("wp_1", Duration.ZERO, Duration.ofSeconds(1)));

    assertEquals("wp_1", error.waitpointId());
  }

  @Test
  @DisplayName("X-30: lease and ack carry the lease and the records")
  void leaseAndAck() throws Exception {
    Stub stub =
        new Stub()
            .reply(201, "{\"object\":\"mailbox_lease\",\"lease_id\":\"l1\",\"records\":[]}")
            .reply(200, "{\"object\":\"mailbox_ack\",\"results\":[],\"acked_cursor\":\"c\"}");
    RelayClient client = stub.client();
    client.agents().leaseMailbox(5);
    client.agents().ackMailbox("l1", List.of("mbr_1", "mbr_2"));

    assertEquals(
        "{\"max\":5}", new String(stub.requests.get(0).body(), StandardCharsets.UTF_8));
    assertEquals(
        "{\"lease_id\":\"l1\",\"record_ids\":[\"mbr_1\",\"mbr_2\"]}",
        new String(stub.requests.get(1).body(), StandardCharsets.UTF_8));
    assertEquals("https://relay.example.com/v1/mailbox/acks", stub.requests.get(1).uri().toString());
  }

  @Test
  @DisplayName("X-30: follow opens the stream, reads the history, then reads after each hint once per record")
  void follow() {
    List<String> order = new ArrayList<>();
    Stub stub =
        new Stub()
            .answer(
                request -> {
                  order.add("history");
                  return Stub.response(200, records("c1", true, false, "mbr_1", "mbr_2"));
                })
            .reply(200, records("c2", false, false, "mbr_2", "mbr_3"))
            .reply(200, records("c2", false, true))
            .reply(200, records("c3", false, false, "mbr_3", "mbr_4"));
    Iterable<String> hints =
        () -> {
          order.add("stream");
          return new Iterator<>() {
            private int left = 1;

            @Override
            public boolean hasNext() {
              return left > 0;
            }

            @Override
            public String next() {
              left--;
              return "hint";
            }
          };
        };
    List<String> handled = new ArrayList<>();
    stub.client().agents().follow(hints, record -> handled.add(record.path("id").asText()));

    assertEquals(List.of("stream", "history"), order);
    assertEquals(List.of("mbr_1", "mbr_2", "mbr_3", "mbr_4"), handled);
    assertEquals(
        "https://relay.example.com/v1/mailbox/records?limit=100",
        stub.requests.get(0).uri().toString());
    assertEquals(
        "https://relay.example.com/v1/mailbox/records?limit=100&since=c1",
        stub.requests.get(1).uri().toString());
    assertEquals(
        "https://relay.example.com/v1/mailbox/records?limit=100&since=c2",
        stub.requests.get(3).uri().toString());
  }

  @Test
  @DisplayName("X-30: the dedupe keeps the most recent identifiers")
  void dedupe() {
    Dedupe seen = new Dedupe(2);
    assertEquals(true, seen.add("a"));
    assertEquals(false, seen.add("a"));
    seen.add("b");
    seen.add("c");
    assertEquals(true, seen.add("a"));
  }
}
