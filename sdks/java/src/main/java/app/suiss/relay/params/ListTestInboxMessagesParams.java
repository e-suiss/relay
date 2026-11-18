package app.suiss.relay.params;

/** Query parameters of {@code listTestInboxMessages}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListTestInboxMessagesParams extends QueryParams<ListTestInboxMessagesParams> {
  /** Creates an empty parameter set. */
  public ListTestInboxMessagesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTestInboxMessagesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTestInboxMessagesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTestInboxMessagesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListTestInboxMessagesParams self() {
    return this;
  }
}
