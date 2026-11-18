package app.suiss.relay.params;

/** Query parameters of {@code listSuppressions}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListSuppressionsParams extends QueryParams<ListSuppressionsParams> {
  /** Creates an empty parameter set. */
  public ListSuppressionsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSuppressionsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSuppressionsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSuppressionsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code channel}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSuppressionsParams channel(String value) {
    return set("channel", value);
  }

  /**
   * Sets {@code reason}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSuppressionsParams reason(String value) {
    return set("reason", value);
  }

  /**
   * Sets {@code state}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSuppressionsParams state(String value) {
    return set("state", value);
  }

  @Override
  protected ListSuppressionsParams self() {
    return this;
  }
}
