package app.suiss.relay;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * A bounded set of identifiers seen recently. Delivery is at least once, so a reader keeps the
 * identifiers it handled and skips them when they come again.
 */
public final class Dedupe {
  private final Recent seen;

  /**
   * Creates a set that keeps the most recent identifiers.
   *
   * @param capacity how many identifiers to keep
   */
  public Dedupe(int capacity) {
    if (capacity < 1) {
      throw new IllegalArgumentException("capacity must be positive");
    }
    this.seen = new Recent(capacity);
  }

  /**
   * Records an identifier.
   *
   * @param id the identifier
   * @return true when it was not seen before
   */
  public synchronized boolean add(String id) {
    return seen.put(id, Boolean.TRUE) == null;
  }

  private static final class Recent extends LinkedHashMap<String, Boolean> {
    private static final long serialVersionUID = 1L;

    private final int capacity;

    Recent(int capacity) {
      this.capacity = capacity;
    }

    @Override
    protected boolean removeEldestEntry(Map.Entry<String, Boolean> eldest) {
      return size() > capacity;
    }
  }
}
