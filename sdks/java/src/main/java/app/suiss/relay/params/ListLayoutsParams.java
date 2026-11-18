package app.suiss.relay.params;

/** Query parameters of {@code listLayouts}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListLayoutsParams extends QueryParams<ListLayoutsParams> {
  /** Creates an empty parameter set. */
  public ListLayoutsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListLayoutsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListLayoutsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListLayoutsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListLayoutsParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected ListLayoutsParams self() {
    return this;
  }
}
