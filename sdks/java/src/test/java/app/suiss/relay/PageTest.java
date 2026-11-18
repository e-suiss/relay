package app.suiss.relay;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import app.suiss.relay.params.ListWaitpointsParams;
import com.fasterxml.jackson.databind.JsonNode;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

class PageTest {
  private static String page(boolean hasMore, String cursor, String... ids) {
    StringBuilder data = new StringBuilder();
    for (String id : ids) {
      if (data.length() > 0) {
        data.append(',');
      }
      data.append("{\"id\":\"").append(id).append("\"}");
    }
    return "{\"object\":\"list\",\"data\":["
        + data
        + "],\"has_more\":"
        + hasMore
        + ",\"next_cursor\":"
        + (cursor == null ? "null" : "\"" + cursor + "\"")
        + "}";
  }

  @Test
  @DisplayName("API-56: the iterator fetches the next page only when the previous one is used up")
  void lazy() {
    Stub stub =
        new Stub()
            .reply(200, page(true, "c1", "wp_1", "wp_2"))
            .reply(200, page(true, "c2", "wp_3"))
            .reply(200, page(false, null, "wp_4"));
    Page first =
        stub.client()
            .api()
            .listWaitpoints(new ListWaitpointsParams().limit(2), RequestOptions.none());

    assertEquals(1, stub.requests.size());
    assertEquals(2, first.data().size());
    assertTrue(first.hasMore());
    assertEquals("c1", first.nextCursor());

    Iterator<JsonNode> items = first.autoPaging().iterator();
    List<String> seen = new ArrayList<>();
    seen.add(items.next().path("id").asText());
    seen.add(items.next().path("id").asText());
    assertEquals(1, stub.requests.size());
    seen.add(items.next().path("id").asText());
    assertEquals(2, stub.requests.size());
    while (items.hasNext()) {
      seen.add(items.next().path("id").asText());
    }
    assertFalse(items.hasNext());
    assertEquals(List.of("wp_1", "wp_2", "wp_3", "wp_4"), seen);
    assertEquals(3, stub.requests.size());
    assertEquals(
        "https://relay.example.com/v1/waitpoints?limit=2&starting_after=c1",
        stub.requests.get(1).uri().toString());
    assertEquals(
        "https://relay.example.com/v1/waitpoints?limit=2&starting_after=c2",
        stub.requests.get(2).uri().toString());
  }

  @Test
  @DisplayName("API-56: the last page has no next page")
  void lastPage() {
    Stub stub = new Stub().reply(200, page(false, null, "wp_1"));
    Page first = stub.client().api().listWaitpoints();

    assertEquals(null, first.nextPage());
    assertEquals(1, first.stream().count());
    assertEquals(1, stub.requests.size());
  }
}
