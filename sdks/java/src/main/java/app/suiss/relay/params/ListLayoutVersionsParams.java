package app.suiss.relay.params;

/** Query parameters of {@code listLayoutVersions}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListLayoutVersionsParams extends QueryParams<ListLayoutVersionsParams> {
  /** Creates an empty parameter set. */
  public ListLayoutVersionsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListLayoutVersionsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListLayoutVersionsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListLayoutVersionsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListLayoutVersionsParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected ListLayoutVersionsParams self() {
    return this;
  }
}
