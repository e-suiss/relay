package app.suiss.relay.params;

/** Query parameters of {@code listEventTypeMappings}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListEventTypeMappingsParams extends QueryParams<ListEventTypeMappingsParams> {
  /** Creates an empty parameter set. */
  public ListEventTypeMappingsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListEventTypeMappingsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListEventTypeMappingsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListEventTypeMappingsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListEventTypeMappingsParams self() {
    return this;
  }
}
