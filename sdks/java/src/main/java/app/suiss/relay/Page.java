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
 * following pages, fetching a page only when the previous one is used up.
 */
public final class Page {
  private final JsonNode raw;
  private final List<JsonNode> data;
  private final boolean hasMore;
  private final String nextCursor;
  private final Function<String, Page> fetchAfter;

  Page(JsonNode raw, Function<String, Page> fetchAfter) {
    this.raw = raw;
    List<JsonNode> items = new ArrayList<>();
    raw.path("data").forEach(items::add);
    this.data = Collections.unmodifiableList(items);
    this.hasMore = raw.path("has_more").asBoolean(false);
    JsonNode cursor = raw.path("next_cursor");
    this.nextCursor = cursor.isTextual() ? cursor.textValue() : null;
    this.fetchAfter = fetchAfter;
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
   * The page as Relay returned it.
   *
   * @return the list object
   */
  public JsonNode raw() {
    return raw;
  }

  /**
   * Fetches the next page.
   *
   * @return the next page, or null when this is the last one
   */
  public Page nextPage() {
    return hasMore && nextCursor != null ? fetchAfter.apply(nextCursor) : null;
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
      this.items = first.data.iterator();
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
        items = next.data.iterator();
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
