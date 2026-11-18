package app.suiss.relay.params;

/** Query parameters of {@code listExports}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListExportsParams extends QueryParams<ListExportsParams> {
  /** Creates an empty parameter set. */
  public ListExportsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListExportsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListExportsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListExportsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListExportsParams self() {
    return this;
  }
}
