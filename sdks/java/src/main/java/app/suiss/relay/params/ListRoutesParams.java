package app.suiss.relay.params;

/** Query parameters of {@code listRoutes}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListRoutesParams extends QueryParams<ListRoutesParams> {
  /** Creates an empty parameter set. */
  public ListRoutesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListRoutesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListRoutesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListRoutesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListRoutesParams self() {
    return this;
  }
}
