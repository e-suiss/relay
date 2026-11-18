package app.suiss.relay.params;

/** Query parameters of {@code listTopics}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListTopicsParams extends QueryParams<ListTopicsParams> {
  /** Creates an empty parameter set. */
  public ListTopicsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTopicsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTopicsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTopicsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListTopicsParams self() {
    return this;
  }
}
