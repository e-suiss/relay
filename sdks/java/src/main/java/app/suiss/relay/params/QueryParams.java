package app.suiss.relay.params;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Query parameters of one operation, in the order they were set.
 *
 * @param <T> the concrete parameter type
 */
public abstract class QueryParams<T extends QueryParams<T>> {
  private final Map<String, String> values = new LinkedHashMap<>();

  /** Creates an empty parameter set. */
  protected QueryParams() {}

  /**
   * Sets a parameter by its wire name.
   *
   * @param name the wire name
   * @param value the value; null removes the parameter
   * @return these parameters
   */
  protected final T set(String name, String value) {
    if (value == null) {
      values.remove(name);
    } else {
      values.put(name, value);
    }
    return self();
  }

  /**
   * Returns this instance with its concrete type.
   *
   * @return this instance
   */
  protected abstract T self();

  /**
   * The parameters by wire name.
   *
   * @return an unmodifiable view of the parameters
   */
  public final Map<String, String> values() {
    return Collections.unmodifiableMap(values);
  }
}
