package app.suiss.relay.params;

/** Query parameters of {@code listSubscriberConsents}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListSubscriberConsentsParams extends QueryParams<ListSubscriberConsentsParams> {
  /** Creates an empty parameter set. */
  public ListSubscriberConsentsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscriberConsentsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscriberConsentsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscriberConsentsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListSubscriberConsentsParams self() {
    return this;
  }
}
