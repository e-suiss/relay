package app.suiss.relay.params;

/** Query parameters of {@code listRecurrences}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListRecurrencesParams extends QueryParams<ListRecurrencesParams> {
  /** Creates an empty parameter set. */
  public ListRecurrencesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListRecurrencesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListRecurrencesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListRecurrencesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListRecurrencesParams self() {
    return this;
  }
}
