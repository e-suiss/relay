package app.suiss.relay.params;

/** Query parameters of {@code listTopicSubscriptions}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListTopicSubscriptionsParams extends QueryParams<ListTopicSubscriptionsParams> {
  /** Creates an empty parameter set. */
  public ListTopicSubscriptionsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTopicSubscriptionsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTopicSubscriptionsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTopicSubscriptionsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListTopicSubscriptionsParams self() {
    return this;
  }
}
