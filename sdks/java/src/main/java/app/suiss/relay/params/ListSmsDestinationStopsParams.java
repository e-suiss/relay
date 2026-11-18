package app.suiss.relay.params;

/** Query parameters of {@code listSmsDestinationStops}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListSmsDestinationStopsParams
    extends QueryParams<ListSmsDestinationStopsParams> {
  /** Creates an empty parameter set. */
  public ListSmsDestinationStopsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSmsDestinationStopsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSmsDestinationStopsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSmsDestinationStopsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code state}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSmsDestinationStopsParams state(String value) {
    return set("state", value);
  }

  @Override
  protected ListSmsDestinationStopsParams self() {
    return this;
  }
}
