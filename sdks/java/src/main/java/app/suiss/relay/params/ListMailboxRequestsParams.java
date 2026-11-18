package app.suiss.relay.params;

/** Query parameters of {@code listMailboxRequests}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListMailboxRequestsParams extends QueryParams<ListMailboxRequestsParams> {
  /** Creates an empty parameter set. */
  public ListMailboxRequestsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListMailboxRequestsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListMailboxRequestsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListMailboxRequestsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListMailboxRequestsParams self() {
    return this;
  }
}
