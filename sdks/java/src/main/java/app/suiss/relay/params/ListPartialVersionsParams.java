package app.suiss.relay.params;

/** Query parameters of {@code listPartialVersions}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListPartialVersionsParams extends QueryParams<ListPartialVersionsParams> {
  /** Creates an empty parameter set. */
  public ListPartialVersionsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListPartialVersionsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListPartialVersionsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListPartialVersionsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListPartialVersionsParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected ListPartialVersionsParams self() {
    return this;
  }
}
