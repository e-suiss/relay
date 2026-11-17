package app.suiss.relay;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import java.util.NoSuchElementException;
import java.util.Spliterator;
import java.util.Spliterators;
import java.util.function.Function;
import java.util.stream.Stream;
import java.util.stream.StreamSupport;

/**
 * One page of a cursor-paginated list. {@link #autoPaging()} walks every item of this and the
 * following pages, fetching a page only when the previous one is used up. A list that started with
 * {@code ending_before} is walked backwards, each page's items in reverse order.
 */
public final class Page {
  private final JsonNode raw;
  private final List<JsonNode> data;
  private final boolean hasMore;
  private final String nextCursor;
  private final String previousCursor;
  private final boolean backward;
  private final Function<String, Page> fetch;

  Page(JsonNode raw, boolean backward, Function<String, Page> fetch) {
    this.raw = raw;
    List<JsonNode> items = new ArrayList<>();
    raw.path("data").forEach(items::add);
    this.data = Collections.unmodifiableList(items);
    this.hasMore = raw.path("has_more").asBoolean(false);
    JsonNode cursor = raw.path("next_cursor");
    this.nextCursor = cursor.isTextual() ? cursor.textValue() : null;
    JsonNode previous = raw.path("previous_cursor");
    this.previousCursor = previous.isTextual() ? previous.textValue() : null;
    this.backward = backward;
    this.fetch = fetch;
  }

  /**
   * The items of this page.
   *
   * @return the items
   */
  public List<JsonNode> data() {
    return data;
  }

  /**
   * Whether more items follow this page.
   *
   * @return true when a next page exists
   */
  public boolean hasMore() {
    return hasMore;
  }

  /**
   * The cursor of the next page.
   *
   * @return the cursor, or null
   */
  public String nextCursor() {
    return nextCursor;
  }

  /**
   * The cursor of the previous page.
   *
   * @return the cursor, or null
   */
  public String previousCursor() {
    return previousCursor;
  }

  /**
   * The page as Relay returned it.
   *
   * @return the list object
   */
  public JsonNode raw() {
    return raw;
  }

  /**
   * Fetches the next page in the direction of the walk: after {@code next_cursor}, or before {@code
   * previous_cursor} for a list that started with {@code ending_before}.
   *
   * @return the next page, or null when this is the last one
   */
  public Page nextPage() {
    String cursor = backward ? previousCursor : nextCursor;
    return cursor == null ? null : fetch.apply(cursor);
  }

  private Iterator<JsonNode> walkItems() {
    if (!backward) {
      return data.iterator();
    }
    List<JsonNode> reversed = new ArrayList<>(data);
    Collections.reverse(reversed);
    return reversed.iterator();
  }

  /**
   * Every item of this and the following pages, fetched lazily.
   *
   * @return an iterable that can be walked once per call to {@code iterator()}
   */
  public Iterable<JsonNode> autoPaging() {
    return () -> new Walker(this);
  }

  /**
   * Every item of this and the following pages as a lazy stream.
   *
   * @return the stream
   */
  public Stream<JsonNode> stream() {
    return StreamSupport.stream(
        Spliterators.spliteratorUnknownSize(new Walker(this), Spliterator.ORDERED), false);
  }

  private static final class Walker implements Iterator<JsonNode> {
    private Page page;
    private Iterator<JsonNode> items;

    Walker(Page first) {
      this.page = first;
      this.items = first.walkItems();
    }

    @Override
    public boolean hasNext() {
      while (!items.hasNext()) {
        Page next = page == null ? null : page.nextPage();
        if (next == null) {
          page = null;
          return false;
        }
        page = next;
        items = next.walkItems();
      }
      return true;
    }

    @Override
    public JsonNode next() {
      if (!hasNext()) {
        throw new NoSuchElementException();
      }
      return items.next();
    }
  }
}
