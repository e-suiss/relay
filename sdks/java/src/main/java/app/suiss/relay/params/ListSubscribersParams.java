package app.suiss.relay.params;

/** Query parameters of {@code listSubscribers}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListSubscribersParams extends QueryParams<ListSubscribersParams> {
  /** Creates an empty parameter set. */
  public ListSubscribersParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscribersParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscribersParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscribersParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListSubscribersParams self() {
    return this;
  }
}
